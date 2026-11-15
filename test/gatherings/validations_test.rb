require_relative '../test_config'

# A gathering's member limit, its money settings and the rules on proposing and supporting applications, tested on the
# models: the forms that set them check nothing first
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

  # ═══════════════════════════════════════════════════════════════════════════
  # Verdicts on applications
  # ═══════════════════════════════════════════════════════════════════════════

  def pending_mapplication(created_at: Time.now)
    @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending').tap { |mapplication| mapplication.set(created_at: created_at) }
  end

  test "a proposer can't propose until the application is the gathering's proposing delay old" do
    create_gathering(privacy: 'closed', fixed_threshold: 2, proposing_delay: 24)
    member = create_gathering_member

    too_soon = pending_mapplication(created_at: 24.hours.ago + 1.minute)
    verdict = too_soon.verdicts.build(account: member, type: 'proposer')
    refute verdict.save
    assert_equal ['is restricted by gathering.proposing_delay'], verdict.errors[:type]
    assert_equal 0, too_soon.verdicts.count
    # The delay is on proposing: supporting isn't held back
    assert too_soon.verdicts.create(account: create_gathering_member, type: 'supporter').persisted?

    old_enough = pending_mapplication(created_at: 24.hours.ago - 1.minute)
    assert old_enough.verdicts.create(account: member, type: 'proposer').persisted?

    # With no delay, an application can be proposed straight away
    @gathering.set(proposing_delay: nil)
    assert pending_mapplication.verdicts.create(account: member, type: 'proposer').persisted?
  end

  test 'a proposer or supporter gives a reason when the gathering requires one, and need not otherwise' do
    create_gathering(privacy: 'closed', fixed_threshold: 5, enable_supporters: true, require_reason_proposer: true, require_reason_supporter: true)

    %w[proposer supporter].each do |type|
      mapplication = pending_mapplication
      verdict = mapplication.verdicts.build(account: create_gathering_member, type: type)
      refute verdict.save, type
      assert_equal ['requires a reason'], verdict.errors[:type], type
      assert_equal 0, mapplication.verdicts.count, type
      assert mapplication.verdicts.create(account: create_gathering_member, type: type, reason: 'I know them well').persisted?, type
    end

    # Each setting is for its own kind of verdict
    @gathering.set(require_reason_supporter: false)
    gathering = Gathering.find(@gathering.id)
    mapplication = gathering.mapplications.find(pending_mapplication.id)
    assert mapplication.verdicts.create(account: create_gathering_member, type: 'supporter').persisted?
    refute mapplication.verdicts.build(account: create_gathering_member, type: 'proposer').valid?

    @gathering.set(require_reason_proposer: false)
    mapplication = Gathering.find(@gathering.id).mapplications.find(pending_mapplication.id)
    assert mapplication.verdicts.create(account: create_gathering_member, type: 'proposer').persisted?
  end
end
