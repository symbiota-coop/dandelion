# safe_load snapshots every class in the process around each require so development
# can reload a file. Tests never reload, and the snapshots dominate boot.
module Padrino
  module Reloader
    class << self
      def safe_load(file, options = {})
        file = figure_path(file)
        return unless options[:force] || file_changed?(file)

        require(file)
        update_modification_time(file)
      end
    end
  end
end
