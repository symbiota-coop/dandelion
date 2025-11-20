FactoryBot.define do
  factory :account do
    sequence(:name) { |n| "Account #{n}" }
    sequence(:email) { |n| "account#{n}@#{ENV['DOMAIN']}" }
    sequence(:password) { |_n| Account.generate_password }
    location { 'Stockholm, Sweden' }
  end

  factory :organisation do
    sequence(:name) { |n| "Organisation #{n}" }
    sequence(:slug) { |n| "organisation-#{n}" }
    stripe_pk { ENV['STRIPE_PK'] }
    stripe_sk { ENV['STRIPE_SK'] }
    account
  end

  factory :organisationship do
    organisation
    account
  end

  factory :activity do
    sequence(:name) { |n| "Activity #{n}" }
    sequence(:slug) { |n| "activity-#{n}" }
    organisation
    account
  end

  factory :activityship do
    activity
    account
  end

  factory :local_group do
    sequence(:name) { |n| "Local Group #{n}" }
    sequence(:slug) { |n| "local-group-#{n}" }
    geometry do
      %({
        "type": "Polygon",
        "coordinates": [
          [
            [
              18.069074443876616,
              59.32893414167211
            ],
            [
              18.059304144039203,
              59.32573404852559
            ],
            [
              18.065591933468454,
              59.32154566896662
            ],
            [
              18.078523660000855,
              59.320920425484616
            ],
            [
              18.076072668527303,
              59.328050293108475
            ],
            [
              18.069074443876616,
              59.32893414167211
            ]
          ]
        ]
      })
    end
    organisation
    account
  end

  factory :local_groupship do
    local_group
    account
  end

  factory :gathering do
    sequence(:name) { |n| "Gathering #{n}" }
    sequence(:slug) { |n| "gathering-#{n}" }
    stripe_pk { ENV['STRIPE_PK'] }
    stripe_sk { ENV['STRIPE_SK'] }
    currency { 'GBP' }
    listed { true }
    enable_teams { true }
    enable_timetables { true }
    enable_rotas { true }
    enable_contributions { true }
    enable_inventory { true }
    enable_budget { true }
    account
  end

  factory :ticket_type do
    sequence(:name) { |n| "Ticket Type #{n}" }
    price_or_range_submitted { true }
    price_or_range { 0 }
    sequence(:quantity) { |n| n }
    event
  end

  factory :event do
    sequence(:name) { |n| "Event #{n}" }
    sequence(:start_time) { |n| Time.now + 1.month + n.days }
    sequence(:end_time) { |n| Time.now + 1.month + (n + 1).days }
    location { 'Stockholm, Sweden' }
    currency { 'GBP' }
    organisation
    account
    last_saved_by factory: :account

    transient do
      ticket_types_count { 3 }
      price_or_range { 0 }
    end
    after(:create) do |event, evaluator|
      create_list(:ticket_type, evaluator.ticket_types_count, event: event, price_or_range: evaluator.price_or_range)
      event.reload
    end
  end

  factory :discount_code do
    trait :for_event do
      association :codable, factory: :event
    end
  end

  factory :pmail do
    sequence(:subject) { |n| "Subject #{n}" }
    sequence(:from) { |n| "Account #{n} <account#{n}@#{ENV['DOMAIN']}>" }
    sequence(:body) { |n| "Body text #{n}" }
    organisation
    account
  end
end
