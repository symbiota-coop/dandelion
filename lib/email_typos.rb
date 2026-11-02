# Whether an email address's domain looks like a slip of the keyboard: one or two keystrokes from a common provider's
# (gmial.com, hotmail.con), so that tickets booked for it would go nowhere. OrderBuilder asks the buyer to confirm one
module EmailTypos
  # Email providers' domains used by at least 20 Dandelion accounts (as of October 2026), most used first, then smaller ones
  # a slip from those: the domains people mistype, and real ones that shouldn't be 'corrected' to them. Universities,
  # employers and the typos themselves are left out
  DOMAINS = %w[
    gmail.com hotmail.com hotmail.co.uk yahoo.com yahoo.co.uk outlook.com icloud.com aol.com
    googlemail.com live.co.uk me.com btinternet.com comcast.net protonmail.com live.com msn.com
    mac.com gmx.de cox.net sbcglobal.net web.de ymail.com att.net proton.me sky.com mail.com
    pm.me mail.ru rocketmail.com verizon.net hotmail.fr bellsouth.net posteo.de ntlworld.com
    charter.net yahoo.fr yahoo.de t-online.de hotmail.it gmx.net blueyonder.co.uk seznam.cz
    gmx.com duck.com yahoo.ca talktalk.net gmx.at hotmail.de wp.pl rogers.com virginmedia.com
    optonline.net yahoo.it aol.co.uk yandex.ru orange.fr earthlink.net bluewin.ch yahoo.com.au
    btopenworld.com tiscali.co.uk naver.com libero.it talk21.com yahoo.es gmx.co.uk tutanota.com
    posteo.net aim.com email.com riseup.net gmx.ch live.ca live.fr live.nl phonecoop.coop wanadoo.fr live.de
    live.se mailbox.org freenet.de o2.pl windstream.net sympatico.ca live.com.au hotmail.es
    virgin.net frontier.com fastmail.com bigpond.com free.fr tutamail.com zoho.com live.it hey.com
    outlook.de yahoo.ie protonmail.ch 163.com bk.ru yandex.com yahoo.com.br tuta.io qq.com
    outlook.fr fastmail.fm btconnect.com embarqmail.com shaw.ca ukr.net email.cz abv.bg hotmail.ca
    laposte.net juno.com roadrunner.com opayq.com telenet.be twc.com passmail.net yahoo.gr yahoo.se
    netscape.net hanmail.net live.dk nate.com sfr.fr zen.co.uk inbox.lv list.ru
    op.pl vp.pl online.de online.no q.com mozmail.com myyahoo.com y7mail.com mail.co.uk yopmail.com foxmail.com
  ].freeze

  # Endings that are a slip from .com, .net or .org (and never a real one people use)
  TLD_SLIPS = %w[con cmo ocm vom xom comm nte ent ner ogr prg].freeze

  # The endings of a provider's domains in other countries (nl, co.in, com.au)
  COUNTRY_ENDING = /\A((co|com|net)\.)?[a-z]{2}\z/

  def self.mistyped?(email)
    at = email.to_s.rindex('@')
    return false if at.nil? || at < 1

    domain = email.to_s[(at + 1)..].strip.downcase
    return false if domain.empty? || DOMAINS.include?(domain)
    return true if TLD_SLIPS.include?(domain.split('.').last)

    # Short domains are closer to each other, so only one slip is allowed in those. A provider with domains in several
    # countries is most likely real at another country's (hotmail.nl, yahoo.co.in), unless the ending was cut short
    # (hotmail.co)
    allowed = domain.length <= 8 ? 1 : 2
    name = domain.split('.').first
    ending = domain[(name.length + 1)..].to_s
    countries = DOMAINS.count { |known| known.split('.').first == name } > 1
    DOMAINS.any? do |known|
      known_name = known.split('.').first
      next false if known_name == name && countries && ending.match?(COUNTRY_ENDING) && !known[(known_name.length + 1)..].start_with?(ending)

      edit_distance(domain, known) <= allowed
    end
  end

  # How many insertions, deletions, substitutions and swaps of neighbouring letters turn a into b
  def self.edit_distance(a, b)
    d = Array.new(a.length + 1) { |i| [i] + Array.new(b.length, 0) }
    (0..b.length).each { |j| d[0][j] = j }
    (1..a.length).each do |i|
      (1..b.length).each do |j|
        cost = a[i - 1] == b[j - 1] ? 0 : 1
        d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
        d[i][j] = [d[i][j], d[i - 2][j - 2] + 1].min if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]
      end
    end
    d[a.length][b.length]
  end
end
