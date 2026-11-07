#!/usr/bin/env ruby
# A Gmail MCP server for the user query replies workflow (.github/workflows/user-query-replies.yml): it lists and reads
# inbox threads and drafts replies, but can't send. It builds each draft's MIME itself, as the agents got it wrong
# (Gmail's own MCP rewrites links, and email.generator folds In-Reply-To so Gmail drops the draft from the thread).
# Only the standard library, so it runs without bundle install:
#
#   ruby script/gmail_mcp.rb              serves MCP over stdio
#   ruby script/gmail_mcp.rb count QUERY  prints how many messages match a Gmail search (up to 100)
#
# Needs GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET and GMAIL_REFRESH_TOKEN, a refresh token with the gmail.modify scope
require 'cgi/escape'
require 'json'
require 'net/http'
require 'time'

class Gmail
  class Error < StandardError; end

  API = 'https://gmail.googleapis.com/gmail/v1/users/me'.freeze
  FROM = 'Stephen Reid <stephen@symbiota.coop>'.freeze
  MAX_TEXT = 20_000 # characters of each message get_thread returns
  QUOTE_STYLE = 'margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex'.freeze

  def initialize(client_id:, client_secret:, refresh_token:)
    @client_id = client_id
    @client_secret = client_secret
    @refresh_token = refresh_token
  end

  def count(query)
    (request(:get, 'messages', params: { q: query, maxResults: 100 })['messages'] || []).size
  end

  def list_threads(query, max_results)
    threads = request(:get, 'threads', params: { q: query, maxResults: max_results })['threads'] || []
    threads.map do |t|
      messages = request(:get, "threads/#{t['id']}", params: { format: 'metadata', metadataHeaders: %w[From Subject Date] })['messages']
      latest = messages.reject { |m| draft?(m) }.last
      {
        thread_id: t['id'],
        subject: header(messages.first, 'Subject'),
        messages: messages.count { |m| !draft?(m) },
        latest_from: header(latest, 'From'),
        latest_date: header(latest, 'Date'),
        latest_is_mine: sent?(latest),
        has_draft: messages.any? { |m| draft?(m) },
        snippet: CGI.unescapeHTML(latest['snippet'].to_s)
      }
    end
  end

  def get_thread(thread_id)
    request(:get, "threads/#{thread_id}", params: { format: 'full' })['messages'].reject { |m| draft?(m) }.map do |m|
      {
        from: header(m, 'From'),
        to: header(m, 'To'),
        cc: header(m, 'Cc'),
        date: header(m, 'Date'),
        subject: header(m, 'Subject'),
        mine: sent?(m),
        text: text(m)[0, MAX_TEXT]
      }
    end
  end

  # Replies to the latest message in the thread, quoting it as Gmail does
  def create_draft(thread_id, html)
    messages = request(:get, "threads/#{thread_id}", params: { format: 'full' })['messages']
    raise Error, 'This thread already has a draft' if messages.any? { |m| draft?(m) }

    inbound = messages.last
    raise Error, 'The latest message in this thread is yours' if sent?(inbound)

    message_id = one_line(header(inbound, 'Message-ID'))
    raise Error, 'The latest message has no Message-ID' unless message_id

    to = one_line(header(inbound, 'Reply-To') || header(inbound, 'From'))
    subject = one_line(header(inbound, 'Subject')).to_s
    subject = "Re: #{subject}" unless subject.match?(/\Are:/i)
    mime = [
      "From: #{FROM}",
      "To: #{encode_address(to)}",
      "Subject: #{encode_words(subject)}",
      "In-Reply-To: #{message_id}",
      "References: #{[one_line(header(inbound, 'References')), message_id].compact.join(' ')}",
      'MIME-Version: 1.0',
      'Content-Type: text/html; charset=UTF-8',
      'Content-Transfer-Encoding: quoted-printable',
      '',
      quoted_printable("#{html}<br><br>#{quote(inbound)}")
    ].join("\r\n")

    draft = request(:post, 'drafts', body: { message: { raw: base64url(mime), threadId: thread_id } })
    saved = request(:get, "drafts/#{draft['id']}", params: { format: 'raw' })['message']
    unless saved['threadId'] == thread_id && unbase64url(saved['raw']).match?(/^In-Reply-To: #{Regexp.escape(message_id)}\r?$/i)
      request(:delete, "drafts/#{draft['id']}")
      raise Error, "Gmail didn't keep the draft in the thread, so it was deleted"
    end
    { draft_id: draft['id'], thread_id:, to:, subject: }
  end

  private

  def request(method, path, params: {}, body: nil)
    uri = URI("#{API}/#{path}")
    uri.query = URI.encode_www_form(params) if params.any?
    req = Net::HTTP.const_get(method.capitalize).new(uri)
    req['Authorization'] = "Bearer #{access_token}"
    if body
      req['Content-Type'] = 'application/json'
      req.body = body.to_json
    end
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    raise Error, "Gmail #{method.upcase} #{path}: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)

    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end

  # Access tokens last an hour, so refresh one a minute early
  def access_token
    return @access_token if @access_token && Time.now < @expires_at

    res = Net::HTTP.post_form(URI('https://oauth2.googleapis.com/token'), client_id: @client_id, client_secret: @client_secret,
                                                                          refresh_token: @refresh_token, grant_type: 'refresh_token')
    raise Error, "Couldn't refresh the Gmail access token: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)

    token = JSON.parse(res.body)
    @expires_at = Time.now + token['expires_in'].to_i - 60
    @access_token = token['access_token']
  end

  def header(message, name)
    message.dig('payload', 'headers')&.find { |h| h['name'].casecmp?(name) }&.dig('value')
  end

  def draft?(message) = message['labelIds'].to_a.include?('DRAFT')
  def sent?(message) = message['labelIds'].to_a.include?('SENT')

  # Unfolds a header and drops line breaks, so a value can't add headers of its own
  def one_line(value) = value&.gsub(/\s+/, ' ')&.strip

  def part(payload, mime_type)
    return payload if payload['mimeType'] == mime_type && payload.dig('body', 'data')

    payload['parts'].to_a.each do |p|
      found = part(p, mime_type)
      return found if found
    end
    nil
  end

  def decode(part)
    data = unbase64url(part.dig('body', 'data'))
    charset = part['headers'].to_a.find { |h| h['name'].casecmp?('Content-Type') }&.dig('value')&.[](/charset="?([\w.:-]+)/i, 1)
    begin
      data.force_encoding(Encoding.find(charset || 'UTF-8'))
    rescue ArgumentError
      data.force_encoding('UTF-8')
    end
    data.encode('UTF-8', invalid: :replace, undef: :replace).scrub
  end

  def text(message)
    if (plain = part(message['payload'], 'text/plain'))
      decode(plain)
    elsif (html = part(message['payload'], 'text/html'))
      # Any < or > left after the tags go (a stray one, or one a nested tag like <scr<script></script>ipt> leaves) is
      # dropped too, as text's own are escaped as &lt; and &gt;
      stripped = decode(html).gsub(%r{<(style|script)\b.*?</\1>}mi, '').gsub(%r{<br\s*/?>|</(p|div|tr|li|h\d)>}i, "\n").gsub(/<[^>]*>/, '')
      CGI.unescapeHTML(stripped.gsub(/[<>]/, '')).gsub(/\n{3,}/, "\n\n").strip
    else
      ''
    end
  end

  # The message's HTML (or its text, as HTML) inside a Gmail quote, without its images, whose parts aren't attached
  def quote(message)
    body = if (html = part(message['payload'], 'text/html'))
             decoded = decode(html)
             decoded[%r{<body\b[^>]*>(.*)</body>}mi, 1] || decoded
           else
             CGI.escapeHTML(text(message)).gsub("\n", '<br>')
           end
    date = begin
      Time.rfc2822(header(message, 'Date')).strftime('%a, %-d %b %Y at %H:%M')
    rescue ArgumentError, TypeError
      header(message, 'Date')
    end
    attribution = CGI.escapeHTML("On #{date}, #{one_line(header(message, 'From'))} wrote:")
    %(<div class="gmail_quote"><div dir="ltr" class="gmail_attr">#{attribution}<br></div>) +
      %(<blockquote class="gmail_quote" style="#{QUOTE_STYLE}">#{body.gsub(/<img\b[^>]*>/i, '')}</blockquote></div>)
  end

  def encode_words(value) = value.ascii_only? ? value : "=?UTF-8?B?#{[value].pack('m0')}?="

  def encode_address(value)
    return value if value.ascii_only?

    name, address = value.match(/\A(.*?)\s*(<[^>]+>)\z/)&.captures
    address ? "#{encode_words(name.delete('"'))} #{address}" : value
  end

  # pack('M') breaks lines with bare LFs, and MIME wants CRLF
  def quoted_printable(html) = [html.gsub("\r\n", "\n")].pack('M').gsub("\n", "\r\n")

  def base64url(data) = [data].pack('m0').tr('+/', '-_')
  def unbase64url(data) = data.to_s.tr('-_', '+/').unpack1('m')
end

module GmailMCP
  TOOLS = [
    {
      name: 'list_threads',
      description: 'Lists the Gmail threads matching a search, newest first, with who sent the latest message, whether ' \
                   "it's yours and whether the thread has a draft",
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'A Gmail search, e.g. in:inbox newer_than:1d' },
          max_results: { type: 'integer', description: 'At most this many threads (default 25)' }
        },
        required: ['query']
      }
    },
    {
      name: 'get_thread',
      description: "Reads a thread's messages, oldest first, as text, without its drafts",
      inputSchema: { type: 'object', properties: { thread_id: { type: 'string' } }, required: ['thread_id'] }
    },
    {
      name: 'create_draft',
      description: "Drafts a reply in the thread to its latest message, from #{Gmail::FROM}, quoting that message " \
                   'below it. Refuses a thread that already has a draft or whose latest message is yours. It only drafts: ' \
                   'nothing is sent',
      inputSchema: {
        type: 'object',
        properties: {
          thread_id: { type: 'string' },
          html: { type: 'string', description: 'The reply alone, as HTML: <br><br> between paragraphs and <a href> for links' }
        },
        required: %w[thread_id html]
      }
    }
  ].freeze

  def self.serve(gmail)
    $stdout.sync = true
    $stdin.each_line do |line|
      message = JSON.parse(line)
      next unless message.key?('id') # notifications get no response

      result = case message['method']
               when 'initialize'
                 { protocolVersion: message.dig('params', 'protocolVersion') || '2025-06-18', capabilities: { tools: {} },
                   serverInfo: { name: 'gmail', version: '1.0.0' } }
               when 'ping' then {}
               when 'tools/list' then { tools: TOOLS }
               when 'tools/call' then call(gmail, message.dig('params', 'name'), message.dig('params', 'arguments') || {})
               end
      response = result ? { result: } : { error: { code: -32_601, message: "Unknown method #{message['method']}" } }
      puts({ jsonrpc: '2.0', id: message['id'] }.merge(response).to_json)
    end
  end

  def self.call(gmail, name, args)
    value = case name
            when 'list_threads' then gmail.list_threads(args.fetch('query'), args['max_results'] || 25)
            when 'get_thread' then gmail.get_thread(args.fetch('thread_id'))
            when 'create_draft' then gmail.create_draft(args.fetch('thread_id'), args.fetch('html'))
            else raise Gmail::Error, "Unknown tool #{name}"
            end
    { content: [{ type: 'text', text: JSON.pretty_generate(value) }] }
  rescue Gmail::Error, KeyError, IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
    { content: [{ type: 'text', text: e.message }], isError: true }
  end
end

gmail = Gmail.new(client_id: ENV.fetch('GMAIL_CLIENT_ID'), client_secret: ENV.fetch('GMAIL_CLIENT_SECRET'),
                  refresh_token: ENV.fetch('GMAIL_REFRESH_TOKEN'))
case ARGV
in ['count', query] then puts gmail.count(query)
in [] then GmailMCP.serve(gmail)
end
