Dragonfly.app.configure do
  plugin :imagemagick
  url_format '/media/:job/:name'
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

  secret ENV['DRAGONFLY_SECRET']

  define_url do |app, job, _opts|
    if dj = DragonflyJob.find_by(signature: job.signature)
      "#{ENV['S3_CDN']}/#{dj.uid}"
    else
      dj = DragonflyJob.create(uid: job.store, signature: job.signature)
      app.datastore.url_for(dj.uid)
    end
  end
end
