class OrganisationEdge
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :source, class_name: 'Organisation', inverse_of: :organisation_edges_as_source
  belongs_to_without_parent_validation :sink, class_name: 'Organisation', inverse_of: :organisation_edges_as_sink

  field :mutual_followers, type: Integer

  validates_uniqueness_of :sink, scope: :source

  def self.create_all(organisations)
    org_ids = organisations.pluck(:id)
    return if org_ids.empty?

    org_members = Account.collection.aggregate([
      { '$match' => { 'organisation_ids_cache' => { '$in' => org_ids } } },
      { '$project' => {
        'orgs' => {
          '$filter' => {
            'input' => '$organisation_ids_cache',
            'cond' => { '$in' => ['$$this', org_ids] }
          }
        }
      } },
      { '$unwind' => '$orgs' },
      { '$group' => { '_id' => '$orgs', 'member_ids' => { '$addToSet' => '$_id' } } }
    ]).to_h { |doc| [doc['_id'], doc['member_ids'].to_set] }

    now = Time.now
    edges = []

    org_ids.combination(2).each do |source_id, sink_id|
      source_set = org_members[source_id]
      sink_set = org_members[sink_id]
      mutual = source_set && sink_set ? (source_set & sink_set).size : 0
      next if mutual.zero?

      edges << {
        _id: BSON::ObjectId.new,
        source_id: source_id,
        sink_id: sink_id,
        mutual_followers: mutual,
        created_at: now,
        updated_at: now
      }
    end

    collection.insert_many(edges) if edges.any?
  end
end
