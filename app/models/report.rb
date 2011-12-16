class Report < ActiveRecord::Base
  require 'net/http'
  require 'uri'
  belongs_to :server

  def dt
    datetime.strftime("%Y%m%dT%H%M%SZ")
  end

  def jstdt
    (datetime + 32400).strftime("%Y-%m-%d %H:%M:%S +0900")
  end

  def sjstdt
    (datetime + 32400).strftime("%m-%d %H:%M")
  end

  def build
    summary[/(\d*failed)\((?:svn|make|miniruby)[^)]*\)/]
  end

  def btest
    summary[/ (\d+)BFail /, 1] ? $1+'BF': nil
  end

  def testknownbug
    summary[/ KB(\d+F\d+E) /, 1]
  end

  def test
    t = summary[/ (\d+)NotOK /, 1] ? $1+'F' : nil
    a = [btest, testknownbug, t]
    a.compact!
    a.empty? ? nil : a.join(' ')
  end

  def testall
    summary[/ (\d+F\d+E(?:\d+S)) /, 1] || summary[/(\d*failed)\(test\/\)/, 1]
  end

  def rubyspec
    summary[/ rubyspec:(\d+F\d+E) /, 1] || summary[/(failed)\(git-rubyspec/, 1] || summary[/(\d*failed)\(rubyspec\/\)/, 1]
  end

  def shortsummary
    summary[/^[^\x28]+(?:\s*\([^\x29]*\)|\s*\[[^\x5D]*\])*\s*(\S.*?) \(/, 1]
  end

  def diffstat
    summary[/((?:no )?diff[^)>]*)/, 1]
  end

  def loguri
    server.uri + datetime.strftime("ruby-#{branch}/log/%Y%m%dT%H%M%SZ.log.html.gz")
  end

  def diffuri
    server.uri + datetime.strftime("ruby-#{branch}/log/%Y%m%dT%H%M%SZ.diff.html.gz")
  end

  REG_RCNT = /name="(\d+T\d{6}Z).*?a>\s*(\S.*)<br/

  def self.get_reports(server)
    ary = []
    uri = URI(server.uri)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 10) do |h|
      basepath = uri.path
      puts "getting #{uri.host}#{basepath} ..."
      h.get(basepath).body.scan(/href="ruby-([^"\/]+)/) do |branch,_|
        path = File.join(basepath, 'ruby-' + branch, 'recent.html')
        puts "getting #{uri.host}#{path} ..."
        h.get(path).body.scan(REG_RCNT) do |dt, summary,|
          datetime = Time.utc(*dt.unpack("A4A2A2xA2A2A2"))
        if Report.where(server_id: server.id, branch: branch, datetime: datetime).exists?
          next
        end
        puts "reporting #{server.name} #{branch} #{dt} ..."
        ary.push(
          server_id: server.id,
          datetime: datetime,
          branch: branch,
          revision: summary[/(?:trunk|revision) (\d+)\x29/, 1],
          summary: summary.gsub(/<[^>]*>/, '')
        )
        end
      end
    end
    return ary
  rescue StandardError, EOFError, Timeout::Error, Errno::ECONNREFUSED => e
    p e
    p uri
    puts e.backtrace
    return []
  end

  def self.update
    ary = []
    threads = Server.all.map{|server| Thread.new{ ary.concat self.get_reports(server) } }
    threads.each do |th|
      th.join
      Report.transaction do
        while item = ary.pop
          Report.create! item
        end
      end
    end
  end
end
