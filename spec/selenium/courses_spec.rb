require File.expand_path(File.dirname(__FILE__) + '/common')

describe "courses" do
  it_should_behave_like "in-process server selenium tests"

  context "as a teacher" do

    before (:each) do
      account = Account.default
      account.settings = {:open_registration => true, :no_enrollments_can_create_courses => true, :teachers_can_create_courses => true}
      account.save!
    end

    it "should properly hide the wizard and remember its hidden state" do
      course_with_teacher_logged_in

      get "/getting_started?fresh=1"
      driver.find_element(:css, ".save_button").click
      wizard_box = driver.find_element(:id, "wizard_box")
      keep_trying_until { wizard_box.displayed? }
      wizard_box.find_element(:css, ".close_wizard_link").click

      refresh_page
      wait_for_animations # we need to give the wizard a chance to pop up
      wizard_box = driver.find_element(:id, "wizard_box")
      wizard_box.displayed?.should be_false
    end

    it "should open and close wizard after initial close" do
      def find_wizard_box
        wizard_box = keep_trying_until do
          wizard_box = driver.find_element(:id, "wizard_box")
          wizard_box.should be_displayed
          wizard_box
        end
        wizard_box
      end

      course_with_teacher_logged_in
      get "/getting_started"

      expect_new_page_load { driver.find_element(:css, ".save_button").click }
      wait_for_animations
      wizard_box = find_wizard_box
      wizard_box.find_element(:css, ".close_wizard_link").click
      wait_for_animations
      wizard_box.should_not be_displayed
      checklist_button = driver.find_element(:css, '.wizard_popup_link')
      checklist_button.should be_displayed
      checklist_button.click
      wait_for_animations
      checklist_button.should_not be_displayed
      wizard_box = find_wizard_box
      wizard_box.find_element(:css, ".close_wizard_link").click
      wait_for_animations
      wizard_box.should_not be_displayed
      checklist_button.should be_displayed
    end

    it "should allow content export downloads" do
      course_with_teacher_logged_in
      get "/courses/#{@course.id}/content_exports"
      driver.find_element(:css, "button.submit_button").click
      Delayed::Job.last(:conditions => {:tag => 'ContentExport#export_course_without_send_later'})
      export = keep_trying_until { ContentExport.last }
      export.export_course_without_send_later
      new_download_link = keep_trying_until { driver.find_element(:css, "div#exports a") }
      url = new_download_link.attribute 'href'
      url.should match(%r{/files/\d+/download\?verifier=})
    end

    context "course copy" do
      def course_copy_helper
        course_with_teacher_logged_in
        @second_course = Course.create!(:name => 'second course')
        @second_course.offer!
        5.times do |i|
          @second_course.wiki.wiki_pages.create!(:title => "hi #{i}", :body => "Whatever #{i}")
        end
        #add teacher as a user
        e = @second_course.enroll_teacher(@user)
        e.workflow_state = 'active'
        e.accept
        e.save!
        @second_course.reload

        new_term = Account.default.enrollment_terms.create(:name => 'Test Term')
        third_course = Course.create!(:name => 'third course', :enrollment_term => new_term)
        e = third_course.enroll_teacher(@user)
        e.workflow_state = 'active'
        e.accept
        e.save!

        get "/courses/#{@course.id}/details"

        wait_for_ajaximations
        driver.find_element(:link, I18n.t('links.import', 'Import Content into this Course')).click
        driver.find_element(:css, '#content a.button').click

        select_box = driver.find_element(:id, 'copy_from_course')
        select_box.find_elements(:css, 'optgroup').length.should == 2
        second_group = select_box.find_elements(:css, 'optgroup').last
        second_group.find_elements(:css, 'option').length.should == 1
        second_group.attribute('label').should == 'Test Term'

        click_option('#copy_from_course', 'second course')
        driver.find_element(:css, '#content form').submit

        yield driver if block_given?

        #modify course dates
        driver.find_element(:id, 'copy_shift_dates').click
        #adjust start dates
        driver.find_element(:css, '#copy_old_start_date + img').click
        datepicker_prev
        #adjust end dates
        driver.find_element(:css, '#copy_old_end_date + img').click
        datepicker_next
        #adjust day substitutions
        driver.find_element(:css, '.shift_dates_settings .add_substitution_link').click
        driver.find_element(:css, '.substitutions > .substitution').should be_displayed

        driver.find_element(:id, 'copy_context_form').submit
        wait_for_ajaximations

        # since jobs aren't running
        ContentMigration.last.copy_course_without_send_later

        keep_trying_until { driver.find_element(:css, '#copy_results > h2').should include_text('Copy Succeeded') }
        @course.reload
      end

      it "should copy course content" do
        course_copy_helper
        @course.wiki.wiki_pages.count.should == 5
      end

      it "should copy content if things are unselected in hidden boxes" do
        course_copy_helper do |driver|
          driver.find_element(:id, 'copy_everything').click
          wait_for_ajaximations
          driver.find_element(:id, 'uncheck_everything').click
          driver.find_element(:id, 'copy_everything').click
        end
        @course.wiki.wiki_pages.count.should == 5
      end

      it "should selectively copy content" do
        course_copy_helper do |driver|
          driver.find_element(:id, 'copy_everything').click
          wait_for_ajaximations
          driver.find_element(:id, 'uncheck_everything').click
          @second_course.wiki.wiki_pages[0..2].each do |page|
            driver.find_element(:id, "copy_wiki_pages_#{CC::CCHelper.create_key(page)}").click
          end
        end
        @course.wiki.wiki_pages.count.should == 3
      end

      it "should copy the course" do
        enable_cache do
          course_with_teacher_logged_in
          5.times do |i|
            @course.wiki.wiki_pages.create!(:title => "hi #{i}", :body => "Whatever #{i}")
          end

          get "/courses/#{@course.id}/copy"
          expect_new_page_load { driver.find_element(:css, "div#content form").submit }
          driver.find_element(:id, 'copy_context_form').submit
          wait_for_ajaximations
          driver.find_element(:id, 'copy_everything').click
          wait_for_ajaximations

          keep_trying_until { ContentMigration.last.copy_course_without_send_later }

          keep_trying_until { driver.find_element(:css, '#copy_results > h2').should include_text('Copy Succeeded') }

          @new_course = Course.last(:order => :id)
          get "/courses/#{@new_course.id}"
          driver.find_element(:css, "#no_topics_message span.title").should include_text("No Recent Messages")
          @new_course.wiki.wiki_pages.count.should == 5
        end
      end
    end

    it "should correctly update the course quota" do
      course_with_admin_logged_in

      # first try setting the quota explicitly
      get "/courses/#{@course.id}/details"
      driver.find_element(:link, 'Course Details').click
      form = driver.find_element(:css, "#course_form")
      driver.find_element(:css, "#course_form .edit_course_link").should be_displayed
      form.find_element(:css, ".edit_course_link").click
      quota_input = form.find_element(:css, "input#course_storage_quota_mb")
      quota_input.clear
      quota_input.send_keys("10")
      form.submit
      keep_trying_until { driver.find_element(:css, ".loading_image_holder").nil? rescue true }
      form.find_element(:css, ".course_info.storage_quota_mb").text.should == "10"

      # then try just saving it (without resetting it)
      get "/courses/#{@course.id}/details"
      form = driver.find_element(:css, "#course_form")
      form.find_element(:css, ".course_info.storage_quota_mb").text.should == "10"
      form.find_element(:css, ".edit_course_link").click
      form.submit
      keep_trying_until { driver.find_element(:css, ".loading_image_holder").nil? rescue true }
      form.find_element(:css, ".course_info.storage_quota_mb").text.should == "10"

      # then make sure it's right after a reload
      get "/courses/#{@course.id}/details"
      form = driver.find_element(:css, "#course_form")
      form.find_element(:css, ".course_info.storage_quota_mb").text.should == "10"
      @course.reload
      @course.storage_quota.should == 10.megabytes
    end

    it "should allow moving a student to a different section" do
      # this spec does lots of find_element where we expect that it won't exist.
      driver.manage.timeouts.implicit_wait = 0

      c = course :active_course => true
      users = {:plain => {}, :sis => {}}
      [:plain, :sis].each do |sis_type|
        [:student, :observer, :ta, :teacher].each do |enrollment_type|
          user = {
              :username => "#{enrollment_type}+#{sis_type}@example.com",
              :password => "#{enrollment_type}#{sis_type}1"
          }
          user[:user] = user_with_pseudonym :active_user => true,
                                            :username => user[:username],
                                            :password => user[:password]
          user[:enrollment] = c.enroll_user(user[:user], "#{enrollment_type.to_s.capitalize}Enrollment", :enrollment_state => 'active')
          if sis_type == :sis
            user[:enrollment].sis_source_id = "#{enrollment_type}.sis.1"
            user[:enrollment].save!
          end
          users[sis_type][enrollment_type] = user
        end
      end
      admin = {
          :username => 'admin@example.com',
          :password => 'admin1'
      }
      admin[:user] = account_admin_user :active_user => true
      user_with_pseudonym :user=> admin[:user],
                          :username => admin[:username],
                          :password => admin[:password]
      users[:plain][:admin] = admin

      section = c.course_sections.create!(:name => 'M/W/F')

      users[:plain].each do |user_type, logged_in_user|
        # Students and Observers can't do anything
        next if user_type == :student || user_type == :observer
        create_session(logged_in_user[:user].pseudonyms.first, false)

        get "/courses/#{c.id}/details"

        driver.find_element(:css, '#tab-users-link').click

        users.each do |sis_type, users2|
          users2.each do |enrollment_type, user|
            # Admin isn't actually enrolled
            next if enrollment_type == :admin
            # You can't move yourself
            next if user == logged_in_user

            enrollment = user[:enrollment]
            enrollment_element = driver.find_element(:css, "#enrollment_#{enrollment.id}")
            section_label = enrollment_element.find_element(:css, ".section_name") rescue nil
            section_dropdown = enrollment_element.find_element(:css, ".enrollment_course_section_form .course_section_id") rescue nil
            edit_section_link = enrollment_element.find_element(:css, ".edit_section_link") rescue nil
            unenroll_user_link = enrollment_element.find_element(:css, ".unenroll_user_link") rescue nil

            # Observers don't have a section
            if enrollment_type == :observer
              edit_section_link.should be_nil
              section_label.should be_nil
              next
            end
            section_label.should_not be_nil
            section_label.should be_displayed

            # "hover" over the user to make the links appear
            driver.execute_script("$('.user_list #enrollment_#{enrollment.id} .links').css('visibility', 'visible')")
            # All users can manage students; admins and teachers can manage all enrollment types
            can_modify = enrollment_type == :student || [:admin, :teacher].include?(user_type)
            if sis_type == :plain || logged_in_user == admin
              section_dropdown.should_not be_displayed

              if can_modify
                edit_section_link.should_not be_nil
                unenroll_user_link.should_not be_nil

                # Move sections
                edit_section_link.click
                section_label.should_not be_displayed
                section_dropdown.should be_displayed
                section_dropdown.find_element(:css, "option[value=\"#{section.id.to_s}\"]").click

                keep_trying_until { !section_dropdown.should_not be_displayed }

                enrollment.reload
                enrollment.course_section_id.should == section.id
                section_label.should be_displayed
                section_label.text.should == section.name

                # reset this enrollment for the next user
                enrollment.course_section = c.default_section
                enrollment.save!
              else
                edit_section_link.should be_nil
                unenroll_user_link.should be_nil
              end
            else
              edit_section_link.should be_nil
              if can_modify
                unenroll_user_link.should_not be_nil
                unenroll_user_link.should have_class('cant_unenroll')
              else
                unenroll_user_link.should be_nil
              end
            end
          end
        end
      end
    end

    it "should not redirect to the gradebook when switching courses when viewing a student's grades" do
      teacher = user_with_pseudonym(:username => 'teacher@example.com', :active_all => 1)
      student = user_with_pseudonym(:username => 'student@example.com', :active_all => 1)
      course1 = course_with_teacher_logged_in(:user => teacher, :active_all => 1).course
      student_in_course :user => student, :active_all => 1
      course2 = course_with_teacher(:user => teacher, :active_all => 1).course
      student_in_course :user => student, :active_all => 1
      create_session(teacher.pseudonyms.first, false)

      get "/courses/#{course1.id}/grades/#{student.id}"

      select = driver.find_element(:id, 'course_url')
      options = select.find_elements(:css, 'option')
      options.length.should == 2
      select.click
      find_with_jquery('#course_url option:not([selected])').click

      driver.current_url.should match %r{/courses/#{course2.id}/grades/#{student.id}}
    end
  end

  context "course as a student" do

    def enroll_student(student, accept_invitation)
      if accept_invitation
        @course.enroll_student(student).accept
      else
        @course.enroll_student(student)
      end
    end

    before (:each) do
      course_with_teacher(:active_all => true, :name => 'discussion course')
      @student = user_with_pseudonym(:active_user => true, :username => 'student@example.com', :name => 'student@example.com', :password => 'asdfasdf')
    end

    it "should accept the course invitation" do
      enroll_student(@student, false)

      login_as(@student.name)
      get "/courses/#{@course.id}"
      driver.find_element(:css, ".reminder .button[name='accept'] ").click
      assert_flash_notice_message /Invitation accepted!/
    end

    it "should reject a course invitation" do
      enroll_student(@student, false)

      login_as(@student.name)
      get "/courses/#{@course.id}"
      driver.find_element(:css, ".reminder .reject_button").click
      driver.switch_to.alert.accept
      assert_flash_notice_message /Invitation cancelled./
    end

    it "should validate that a user cannot see a course they are not enrolled in" do
      login_as(@student.name)
      driver.find_element(:css, '#menu').should_not include_text('Courses')
    end
  end
end
