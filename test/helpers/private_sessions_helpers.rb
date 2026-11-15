# Helpers the private session test files (test/accounts) share
module PrivateSessionsHelpers
  def practitioner(**attrs)
    FactoryBot.create(:account, name: 'Sky Practitioner', has_signed_in: true, **attrs)
  end

  # Its slug from its title, with a random end so a test's sessions don't share one (the form fills it in as the title's typed)
  def build_private_session(account, **attrs)
    slug = "#{(attrs[:title] || 'Deep tissue massage').parameterize}-#{SecureRandom.hex(3)}"
    account.private_sessions.new(title: 'Deep tissue massage', slug: slug, tag_names: %w[massage], update_tag_names: true, delivery: 'in_person',
                                 location: 'Stockholm', max_participants: 1, how_to_book: 'Email sky@example.com', **attrs)
  end

  def create_private_session(account, **attrs)
    build_private_session(account, **attrs).tap(&:save!)
  end
end
