require_relative '../test_config'

# A gathering's member limit and its money settings, tested on the models: the forms that set them check nothing first
class GatheringValidationsTest < ActiveSupport::TestCase
  test 'a gathering at its member limit refuses a new membership, and takes one below it' do
    create_gathering(member_limit: 2)
    assert_equal 1, @gathering.memberships.count # its creator

    assert @gathering.memberships.create(account: FactoryBot.create(:account)).persisted?
    assert_equal 2, @gathering.memberships.count

    membership = @gathering.memberships.build(account: FactoryBot.create(:account))
    refute membership.save
    assert_equal ['is full'], membership.errors[:gathering]
    assert_equal 2, Gathering.find(@gathering.id).memberships.count

    # An existing membership still saves
    assert Gathering.find(@gathering.id).memberships.last.update(paid: 5)
  end

  test "lowering a gathering's member limit below its member count raises it to the count" do
    create_gathering
    2.times { @gathering.memberships.create!(account: FactoryBot.create(:account)) }

    assert Gathering.find(@gathering.id).update(member_limit: 1)
    assert_equal 3, Gathering.find(@gathering.id).member_limit
    assert Gathering.find(@gathering.id).update(member_limit: 5)
    assert_equal 5, Gathering.find(@gathering.id).member_limit
  end

  test "a gathering's threshold can't be negative, nor its member limit below 1" do
    create_gathering

    {
      { fixed_threshold: -1 } => [:fixed_threshold, 'cannot be negative'],
      { member_limit: 0 } => [:member_limit, 'must be positive'],
      { member_limit: -1 } => [:member_limit, 'must be positive']
    }.each do |attrs, (attribute, message)|
      gathering = Gathering.find(@gathering.id)
      gathering.assign_attributes(attrs)
      refute gathering.save, attrs.inspect
      assert_equal [message], gathering.errors[attribute], attrs.inspect
    end
    assert_equal([nil, nil], Gathering.find(@gathering.id).then { |g| [g.fixed_threshold, g.member_limit] })

    assert Gathering.find(@gathering.id).update(fixed_threshold: 0, member_limit: 1)
    assert_equal([0, 1], Gathering.find(@gathering.id).then { |g| [g.fixed_threshold, g.member_limit] })
  end

  test "a gathering's Stripe keys have their prefixes, and a public key needs its secret key" do
    create_gathering(stripe_sk: nil, stripe_pk: nil)

    {
      { stripe_sk: 'rk_test_abc' } => [:stripe_sk, 'must start with sk_'],
      { stripe_sk: 'sk_test_abc', stripe_pk: 'sk_test_abc' } => [:stripe_pk, 'must start with pk_'],
      { stripe_pk: 'pk_test_abc' } => [:stripe_sk, 'must be present if Stripe public key is present']
    }.each do |attrs, (attribute, message)|
      gathering = Gathering.find(@gathering.id)
      gathering.assign_attributes(attrs)
      refute gathering.save, attrs.inspect
      assert_equal [message], gathering.errors[attribute], attrs.inspect
    end
    assert_equal([nil, nil], Gathering.find(@gathering.id).then { |g| [g.stripe_sk, g.stripe_pk] })

    assert Gathering.find(@gathering.id).update(stripe_sk: 'sk_test_abc')
    assert Gathering.find(@gathering.id).update(stripe_pk: 'pk_test_abc')
    assert_equal(%w[sk_test_abc pk_test_abc], Gathering.find(@gathering.id).then { |g| [g.stripe_sk, g.stripe_pk] })
  end
end
