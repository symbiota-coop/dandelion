module AccountRecommendations
  extend ActiveSupport::Concern

  def recommend_people!
    create_account_recommendation_cache unless account_recommendation_cache
    account_recommendation_cache.recommend_people!
  end

  def recommend_events!(events_with_participant_ids = Event.live.public.future.map do |event|
    [event.id.to_s, event.attendees.pluck(:id).map(&:to_s)]
  end, people = recommended_people)
    create_account_recommendation_cache unless account_recommendation_cache
    account_recommendation_cache.recommend_events!(events_with_participant_ids, people)
  end

  def recommended_people
    create_account_recommendation_cache unless account_recommendation_cache
    account_recommendation_cache.recommended_people_cache
  end

  def recommended_events
    create_account_recommendation_cache unless account_recommendation_cache
    account_recommendation_cache.recommended_events_cache
  end
end
