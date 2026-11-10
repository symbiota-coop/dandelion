# Our ImageMagick security policy (config/imagemagick/policy.xml), for every identify and convert Dragonfly runs, which
# inherit this process's environment. Prepended, so it applies wherever the host keeps its own (Render's image has none)
ENV['MAGICK_CONFIGURE_PATH'] = [File.expand_path('imagemagick', __dir__), ENV.fetch('MAGICK_CONFIGURE_PATH', nil)].compact.join(':')

Dragonfly.app.configure do
  plugin :imagemagick
  url_format '/media/:job/:name'

  if ENV['S3_BUCKET_NAME']
    datastore :s3, {
      url_scheme: 'https',
      url_host: ENV['S3_HOST'],
      bucket_name: ENV['S3_BUCKET_NAME'],
      access_key_id: ENV['S3_ACCESS_KEY'],
      secret_access_key: ENV['S3_SECRET'],
      region: ENV['S3_REGION'],
      fog_storage_options: {
        endpoint: ENV['S3_ENDPOINT']
      }
    }
  else
    assets_root = File.expand_path('../app/assets', __dir__)
    datastore :file,
              root_path: File.join(assets_root, 'dragonfly'),
              server_root: assets_root
  end

  secret ENV['DRAGONFLY_SECRET']

  define_url do |app, job, _opts|
    if (uid = DragonflyJob.prefetched_uid(job.signature) || DragonflyJob.find_by(signature: job.signature)&.uid)
      if ENV['S3_CDN']
        "#{ENV['S3_CDN']}/#{uid}"
      else
        app.datastore.url_for(uid)
      end
    else
      begin
        uid = job.store
        dj = begin
          DragonflyJob.create!(uid: uid, signature: job.signature)
        rescue Mongo::Error::OperationFailure, Mongoid::Errors::Validations => e
          # Another process (a page view, or warm_image_derivatives in the worker) stored the same derivative first:
          # use theirs and drop our copy. The uniqueness validation sees theirs if it was stored while we made ours,
          # the unique index if it was stored between that validation and our insert
          duplicate = e.is_a?(Mongoid::Errors::Validations) ? e.document.errors.of_kind?(:signature, :taken) : e.code == 11_000
          raise unless duplicate && (existing = DragonflyJob.find_by(signature: job.signature))

          app.datastore.destroy(uid)
          existing
        end
        app.datastore.url_for(dj.uid)
      rescue Dragonfly::Job::Fetch::NotFound
        raise if Padrino.env != :development
      end
    end
  end
end
