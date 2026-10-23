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
    if (dj = DragonflyJob.find_by(signature: job.signature))
      if ENV['S3_CDN']
        "#{ENV['S3_CDN']}/#{dj.uid}"
      else
        app.datastore.url_for(dj.uid)
      end
    else
      begin
        uid = job.store
        dj = begin
          DragonflyJob.create(uid: uid, signature: job.signature)
        rescue Mongo::Error::OperationFailure => e
          # Another process (a page view, or warm_image_derivatives in the worker) stored the same derivative first:
          # use theirs and drop our copy
          raise unless e.code == 11_000 && (existing = DragonflyJob.find_by(signature: job.signature))

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
