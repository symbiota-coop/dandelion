# Joins a sold-out ticket type's waitlist, or the event's own once it's sold out: the steps behind the event page's
# waitlist forms (POST /e/:slug/ticket_type_waitships and /e/:slug/waitship/new), taking plain values so other callers,
# like agents, can join the same way.
#
# It checks the waitlist is open before finding or creating an account, so a refused request makes none. Failures raise
# a WaitlistJoiner::Error, whose message says what went wrong and whose reason says why, for callers to add to it.
class WaitlistJoiner
  class Error < StandardError
    # :ticket_type_waitlists (join a ticket type's instead), :not_sold_out, :no_waitlist, :ticket_type_closed (its
    # sales have ended, it isn't sold out or the event doesn't have ticket type waitlists), :no_name_or_email or
    # :invalid (the details)
    attr_reader :reason

    def initialize(message, reason)
      @reason = reason
      super(message)
    end
  end

  attr_reader :account

  # account: who joins, like an API key's account. Otherwise name and email find the account, or make one; only the
  # signed_in_account, if it's that account, has its name updated
  def initialize(event:, ticket_type: nil, account: nil, name: nil, email: nil, signed_in_account: nil)
    @event = event
    @ticket_type = ticket_type
    @account = account
    @name = name.to_s.strip
    @email = email.to_s.strip
    @signed_in_account = signed_in_account
  end

  # Returns the waitship, or the one the account already had
  def call
    check_open
    find_or_create_account unless @account
    waitship = if @ticket_type
                 @ticket_type.ticket_type_waitships.find_by(account: @account) || TicketTypeWaitship.create(ticket_type: @ticket_type, account: @account)
               else
                 @event.waitships.find_by(account: @account) || @event.waitships.create(account: @account)
               end
    raise Error.new(waitship.errors.full_messages.join('; '), :invalid) unless waitship.persisted?

    waitship
  end

  private

  def check_open
    if @ticket_type
      # TicketTypeWaitship's own check, which doesn't depend on who joins
      eligibility = TicketTypeWaitship.new(ticket_type: @ticket_type)
      eligibility.valid?
      raise Error.new(eligibility.errors[:base].first, :ticket_type_closed) if eligibility.errors[:base].any?
    elsif !@event.event_waitlist_open?
      raise Error.new('This event has a waitlist for each sold-out ticket type.', :ticket_type_waitlists) if @event.ticket_type_waitlists_available?
      raise Error.new("This event isn't sold out.", :not_sold_out) unless @event.sold_out?

      raise Error.new("This event doesn't have a waitlist.", :no_waitlist)
    end
  end

  def find_or_create_account
    raise Error.new('Give a name and email address.', :no_name_or_email) if @name.empty? || @email.empty?

    @account = Account.find_by(email: @email.downcase) || Account.new(name: @name, email: @email, password: Account.generate_password)
    saved = if !@account.persisted?
              @account.save
            elsif @signed_in_account && @signed_in_account.id == @account.id
              @account.update_attributes(name: @name)
            else
              true
            end
    raise Error.new(@account.errors.full_messages.join('; '), :invalid) unless saved
  end
end
