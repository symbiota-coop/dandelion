class DragonflyJob
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model

  field :signature, type: String
  field :uid, type: String

  validates_presence_of :signature, :uid
  validates_uniqueness_of :signature

  # Image urls built in the block (define_url in dragonfly_config.rb) find these jobs' uids with one query, rather
  # than one each
  def self.with_prefetched(jobs)
    previous = Thread.current[:dragonfly_job_uids]
    Thread.current[:dragonfly_job_uids] = (previous || {}).merge(self.and(:signature.in => jobs.map(&:signature).uniq).pluck(:signature, :uid).to_h)
    yield
  ensure
    Thread.current[:dragonfly_job_uids] = previous
  end

  def self.prefetched_uid(signature)
    Thread.current[:dragonfly_job_uids]&.[](signature)
  end
end
