FactoryBot.define do
  factory :account do
    sequence(:name) { |n| "Account #{n}" }
    sequence(:email) { |n| "account#{n}@#{ENV['DOMAIN']}" }
    sequence(:password) { |_n| Account.generate_password }
    location { 'Totnes, UK' }
  end

  factory :organisation do
    sequence(:name) { |n| "Organisation #{n}" }
    sequence(:slug) { |n| "organisation-#{n}" }
    sequence(:stripe_pk) { |n| "pk_test_#{n}" }
    sequence(:stripe_sk) { |n| "sk_test_#{n}" }
    account
  end

  factory :activity do
    sequence(:name) { |n| "Activity #{n}" }
    organisation
    account
  end

  factory :local_group do
    sequence(:name) { |n| "Local Group #{n}" }
    geometry do
      %({
        "type": "Polygon",
        "coordinates": [
          [
            [
              -3.6919426918029785,
              50.42995535679469
            ],
            [
              -3.684024810791015,
              50.42995535679469
            ],
            [
              -3.684024810791015,
              50.434178886043604
            ],
            [
              -3.6919426918029785,
              50.434178886043604
            ],
            [
              -3.6919426918029785,
              50.42995535679469
            ]
          ]
        ]
      })
    end
    organisation
    account
  end

  factory :gathering do
    sequence(:name) { |n| "Gathering #{n}" }
    sequence(:slug) { |n| "gathering-#{n}" }
    currency { 'GBP' }
    listed { true }
    enable_teams { true }
    enable_timetables { true }
    enable_rotas { true }
    enable_contributions { true }
    enable_inventory { true }
    enable_budget { true }
    enable_comments_on_gathering_homepage { false }
    account
  end

  factory :ticket_type do
    sequence(:name) { |n| "Ticket Type #{n}" }
    sequence(:price) { |_n| 0 }
    sequence(:quantity) { |n| n }
    event
  end

  factory :event do
    sequence(:name) { |n| "Event #{n}" }
    sequence(:start_time) { |n| Time.now + 1.month + n.days }
    sequence(:end_time) { |n| Time.now + 1.month + (n + 1).days }
    location { 'Totnes, UK' }
    currency { 'GBP' }
    organisation
    account
    last_saved_by factory: :account

    transient do
      ticket_types_count { 3 }
    end
    after(:create) do |event, evaluator|
      create_list(:ticket_type, evaluator.ticket_types_count, event: event)
      event.reload
    end
  end

  factory :pmail do
    sequence(:subject) { |n| "Subject #{n}" }
    sequence(:from) { |n| "Account #{n} <account#{n}@#{ENV['DOMAIN']}>" }
    sequence(:body) { |n| "Body text #{n}" }
    everyone { true }
    organisation
    account
  end
end
