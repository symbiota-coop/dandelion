# Event ids in a given order (trending or random) that load only the page of events shown, rather than every ranked
# event with its key includes: ~200 ms on the homepage's trending list, which showed 20 of the 100 it loaded
class EventIds < Array
  def paginate(options = {})
    super.tap { |page| page.replace(Event.without_heavy_fields.with_key_includes.in_id_order(page)) }
  end
end
