class OrganisationEdge
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :source, class_name: 'Organisation', inverse_of: :organisation_edges_as_source
  belongs_to_without_parent_validation :sink, class_name: 'Organisation', inverse_of: :organisation_edges_as_sink

  field :mutual_followers, type: Integer

  validates_uniqueness_of :sink, scope: :source

  def self.create_all(organisations)
    organisations.each do |source|
      organisations.each do |sink|
        next if source.id == sink.id
        next if OrganisationEdge.find_by(source: sink, sink: source)

        OrganisationEdge.create(source: source, sink: sink, mutual_followers: source.members.and(:id.in => sink.members.pluck(:id)).count)
      end
    end
  end
end
