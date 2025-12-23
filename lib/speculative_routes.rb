module SpeculativeRoutes
  def self.prerender_routes
    @prerender_routes ||= []
  end

  def self.prefetch_routes
    @prefetch_routes ||= []
  end

  def self.clear!
    @prerender_routes = []
    @prefetch_routes = []
  end

  def self.script
    return unless prerender_routes.any? || prefetch_routes.any?

    speculation_rules = {}
    speculation_rules[:prefetch] = prefetch_routes.sort.map { |route| { where: { href_matches: route }, eagerness: 'immediate' } } if prefetch_routes.any?
    speculation_rules[:prerender] = prerender_routes.sort.map { |route| { where: { href_matches: route }, eagerness: 'moderate' } } if prerender_routes.any?

    %(<script type="speculationrules">\n#{JSON.pretty_generate(speculation_rules)}\n</script>)
  end

  # Patch Padrino's route method to capture prerender/prefetch routes
  module ControllerExtensions
    def get(path, options = {}, &)
      SpeculativeRoutes.prerender_routes << path if options.delete(:prerender) && !SpeculativeRoutes.prerender_routes.include?(path)
      SpeculativeRoutes.prefetch_routes << path if options.delete(:prefetch) && !SpeculativeRoutes.prefetch_routes.include?(path)
      super
    end
  end
end

# Apply the patch
Padrino::Routing::ClassMethods.prepend(SpeculativeRoutes::ControllerExtensions)
