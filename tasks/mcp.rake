require 'json'

# .mcp.json (Claude Code) is the one MCP config to edit; `rake mcp:sync` writes the copies other tools read,
# each in its own format and variable syntax
module McpConfigFiles
  ROOT = File.expand_path('..', __dir__)
  SOURCE = '.mcp.json'.freeze
  VARIABLE = /\$\{(\w+)\}/
  BEARER = /\ABearer \$\{(\w+)\}\z/

  def self.servers
    JSON.parse(File.read(File.join(ROOT, SOURCE)))['mcpServers']
  end

  def self.files
    {
      '.cursor/mcp.json' => cursor,
      '.opencode/opencode.json' => opencode,
      '.codex/config.toml' => codex
    }
  end

  def self.sync
    files.each { |path, content| File.write(File.join(ROOT, path), content) }
  end

  # Cursor takes the same JSON, with ${env:VAR} rather than ${VAR}
  def self.cursor
    "#{JSON.pretty_generate('mcpServers' => servers).gsub(VARIABLE, '${env:\1}')}\n"
  end

  # opencode has remote and local servers, the command and its args in one array, and {env:VAR}
  def self.opencode
    mcp = servers.transform_values do |server|
      if server['url']
        { 'type' => 'remote', 'url' => server['url'], 'headers' => server['headers'] }.compact
      else
        { 'type' => 'local', 'command' => [server['command'], *server['args']], 'environment' => server['env'] }.compact
      end
    end
    "#{JSON.pretty_generate('$schema' => 'https://opencode.ai/config.json', 'mcp' => mcp).gsub(VARIABLE, '{env:\1}')}\n"
  end

  # Codex doesn't expand variables in config.toml: it passes env vars through by name (env_vars),
  # and takes a bearer token from a named env var (bearer_token_env_var)
  def self.codex
    sections = servers.map do |name, server|
      lines = ["[mcp_servers.#{name}]"]
      if server['url']
        lines << "url = #{server['url'].to_json}"
        (server['headers'] || {}).each do |header, value|
          raise "#{SOURCE}: #{name}'s #{header} header can't be written for Codex" unless header == 'Authorization' && value =~ BEARER

          lines << "bearer_token_env_var = #{Regexp.last_match(1).to_json}"
        end
      else
        lines << "command = #{server['command'].to_json}"
        lines.concat(toml_array('args', server['args'])) if server['args']
        if server['env']
          server['env'].each do |var, value|
            raise "#{SOURCE}: #{name}'s #{var} must be \"${#{var}}\" to be passed through to Codex" unless value == "${#{var}}"
          end
          lines.concat(toml_array('env_vars', server['env'].keys))
        end
      end
      lines.join("\n")
    end
    "# Generated from #{SOURCE} by `rake mcp:sync`. Don't edit this file\n\n#{sections.join("\n\n")}\n"
  end

  def self.toml_array(key, values)
    ["#{key} = [", *values.map { |value| "  #{value.to_json}," }, ']']
  end
end

namespace :mcp do
  desc 'Write .cursor/mcp.json, .opencode/opencode.json and .codex/config.toml from .mcp.json'
  task :sync do
    McpConfigFiles.sync
    McpConfigFiles.files.each_key { |path| puts "Wrote #{path}" }
  end
end
