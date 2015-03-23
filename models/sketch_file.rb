class SketchFile < ActiveRecord::Base
  has_many :slices, dependent: :destroy

  scope :in_sync, -> { where(in_sync: true) }

  def self.sync_all
    update_all(in_sync: false)

    results = SketchSyncDropbox.with_client do |client|
      client.search('/design', '.sketch')
    end

    results.each do |res|
      next if res['bytes'] == 0
      next if res['is_dir']
      next if res['path'] =~ /conflicted copy/

      sfile = where(dropbox_path: res['path'].downcase)
               .first_or_create(dropbox_rev: 'unknown')

      if sfile.dropbox_rev == res['rev']
        sfile.update_attribute(:in_sync, true)
      else
        Threaded.enqueue(SyncWorker, sfile.id)
      end
    end
  end

  private

  class SyncWorker
    def self.call(id)
      sfile = SketchFile.find(id)

      sfile_directory = sfile.dropbox_path.gsub(/\.sketch$/, '').scan(/\w+/).join('-')
      FileUtils.mkdir_p(File.join('images', sfile_directory))

      $logger.info 'fetching ' + sfile.dropbox_path
      $logger.info '  into ' + sfile_directory

      Dir.mktmpdir do |tmp|
        metadata = {}

        File.open("#{tmp}/download.sketch", 'w') do |f|
          SketchSyncDropbox.with_client do |client|
            metadata = client.metadata(sfile.dropbox_path)
            f.write client.get_file(sfile.dropbox_path)
          end
        end

        sketchtool_path = File.expand_path('../../vendor/sketchtool', __FILE__)
        `cd #{tmp} && #{sketchtool_path}/bin/sketchtool export slices download.sketch`

        sfile.transaction do
          sfile.slices.delete_all

          files = Dir["#{tmp}/**/*.png"]

          files.map do |f|
            # TODO: Refactor this, there's way too much path munging happening
            # here.
            layer_name = f.gsub("#{tmp}/", '').gsub(/\.png$/, '')
            new_filename = layer_name.scan(/\w+/).join('-') + '.png'
            new_filename_with_path = File.join('images', sfile_directory, new_filename)

            FileUtils.mv(f, new_filename_with_path)

            sfile.slices.create(
              path: '/' + new_filename_with_path,
              layer: layer_name
            )
          end

          sfile.update_attributes(
            in_sync: true,
            dropbox_rev: metadata['rev'],
            last_modified: Time.parse(metadata['modified'])
          )
        end
      end
    rescue => ex
      $logger.error "Syncing image #{sfile.dropbox_path}: #{ex.message}. Retrying..."
      retry
    end
  end
end