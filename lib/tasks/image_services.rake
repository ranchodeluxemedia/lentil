namespace :lentil do
  namespace :image_services do
    namespace :instagram do

      desc "Fetch and import recent images from Instagram that are tagged with the default tag"
      task :fetch_by_tag => :environment do

        begin
          harvester = Lentil::InstagramHarvester.new
          new_image_count = 0
          harvestable_tags = Lentil::Tag.harvestable.collect {|tag| tag.name}
          raise "No tags in harvestable tagsets" if harvestable_tags.empty?

          harvestable_tags.each do |tag|
            instagram_metadata = harvester.fetch_recent_images_by_tag(tag)
            new_image_count += harvester.save_instagram_load(instagram_metadata).size
          end

          puts "#{new_image_count} new images added"
        rescue => e
          Rails.logger.error e.message
          raise e
        end
      end
    end

    desc "Fetch and save image files to the directory specified in the applicaton config"
    task :save_image_files, [:number_of_images, :image_service, :base_directory] => :environment do |t, args|

      args.with_defaults(:number_of_images => 50, :image_service => 'Instagram')

      base_dir = args[:base_directory] || Lentil::Engine::APP_CONFIG["base_image_file_dir"] || nil
      raise "Base directory is required" unless base_dir

      num_to_harvest = args[:number_of_images].to_i

      harvester = Lentil::InstagramHarvester.new

      Lentil::Service.where(:name => args[:image_service]).first.images.where(:file_harvested_date => nil).
        order("file_harvest_failed ASC").limit(num_to_harvest).each do |image|
        begin
          raise "Desination directory does not exist or is not a directory: #{base_dir}" unless File.directory?(base_dir)

          image_file_path = "#{base_dir}/#{image.service.name}"

          if !File.exist?(image_file_path)
            Dir.mkdir(image_file_path)
          else
            raise "Service directory is not a directory: #{image_file_path}" unless File.directory?(image_file_path)
          end
        rescue => e
          Rails.logger.error e.message
          raise e
        end

        begin
          image_data = harvester.harvest_image_data(image)
          # TODO: Currently expects JPEG
          image_file_path += "/#{image.external_identifier}.jpg"
          raise "Image file already exists, will not overwrite" if File.exist?(image_file_path)

          File.open(image_file_path, "wb") do |f|
            f.write image_data
          end

          image.file_harvested_date = DateTime.now
          image.save
          puts "Harvested image #{image.id}"
        rescue => e
          image.file_harvest_failed += 1
          image.save
          Rails.logger.error e.message
          puts e.message
        end
      end
    end

    desc "Test whether image file can still be retrieved"
    task :test_image_files, [:number_of_images, :image_service] => :environment do |t, args|
      args.with_defaults(:number_of_images => 10, :image_service => 'Instagram')

      num_to_check = args[:number_of_images].to_i
      harvester = Lentil::InstagramHarvester.new

      Lentil::Service.unscoped.where(:name => args[:image_service]).first.images.
        where("(file_last_checked IS NULL) OR (file_last_checked < :day)", {:day => 1.day.ago}).
        where("failed_file_checks < 10").
        order("file_last_checked ASC").limit(num_to_check).each do |image|
          image_check = harvester.test_remote_image(image)

          if image_check
            image.failed_file_checks = 0
          elsif image_check == false
            image.failed_file_checks += 1
          end

          image.file_last_checked = DateTime.now
          image.save
      end
    end

    desc "Submit donor agreement as a comment on a given number of approved images.
          Currently, image must have been in the system for at least a week"
    task :submit_donor_agreements, [:number_of_images, :image_service] => :environment do |t, args|
      args.with_defaults(:number_of_images => 1, :image_service => 'Instagram')
      num_to_harvest = args[:number_of_images].to_i

      harvester = Lentil::InstagramHarvester.new

      # If you are running the test_image_files task regularly,
      # deleted images will eventually be ignored by this task.
      Lentil::Service.where(:name => args[:image_service]).first.images.approved.where("lentil_images.created_at < :week", {:week => 1.week.ago}).
              where(:do_not_request_donation => false).
              where(:donor_agreement_submitted_date => nil).order("donor_agreement_failed ASC").
              limit(num_to_harvest).each do |image|
        begin
          donor_agreement = Lentil::Engine::APP_CONFIG["donor_agreement_text"] || nil
          raise "donor_agreement_text must be defined in application config" unless donor_agreement
          harvester.leave_image_comment(image, donor_agreement)
          image.donor_agreement_submitted_date = DateTime.now
          image.save
          puts "Left donor agreement on image #{image.id}"
        rescue => e
          image.donor_agreement_failed += 1
          image.save
          Rails.logger.error e.message
          puts e.message
          raise e
        end
      end
    end
  end
end