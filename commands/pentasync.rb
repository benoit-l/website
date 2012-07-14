# vim: set ts=2 sw=2 et ai ft=ruby:

usage       'pentasync'
aliases     :penta, :ps, :p
summary     'syncs the pentabarf schedule with the local files'

require 'psych'
YAML::ENGINE.yamler = 'psych'
require 'erubis'

module ::PentaHelpers
  # Determine the "name" attribute depending on the object type
  def PentaHelpers.name(o)
    case o
    when Room
      o.conference_room
    when Event
      o.title
    when ScheduleEvent
      o.title
    when Track
      o.conference_track
    when ConferenceDay
      o.name
    when Person
      if (o.first_name.nil? or o.last_name.nil?) and (not o.public_name.nil?)
        o.public_name
      else
        "#{o.first_name} #{o.last_name}"
      end
    else
      raise "unsupported class for name(): #{o.class.to_s}"
    end
  end

  # Determine the identifying attribute depending on the object type
  def PentaHelpers.idattr(o)
    case o
    when Room
      :conference_room_id
    when ScheduleEvent
      :event_id
    when Track
      :conference_track_id
    when Day
      :conference_day_id
    when Person
      :person_id
    else
      raise "unsupported class for idattr(): #{o.class.to_s}"
    end
  end

  # Determine the canonical URL identifier depending on the type
  def PentaHelpers.slug(o)
    require 'active_support/inflector/transliterate'
    require 'active_support/inflector/methods'
    s = if o.respond_to? :slug
          o.slug
        else
          name(o)
        end
    # Inflector takes care of replacing locale specific symbols to
    # something "safe" for URLs without requiring symbol gibberish

    ActiveSupport::Inflector.transliterate(s).downcase.gsub(/\s+/, '_').gsub(/\-/, '_').gsub(/\./, '')
  end

  # Determine the URL depending on the type
  def PentaHelpers.url(o)
    prefix = case o
             when Room
               "/schedule/room/"
             when Person
               "/schedule/speaker/"
             when Event
               "/schedule/event/"
             when ScheduleEvent
               "/schedule/event/"
             when Track
               "/schedule/track/"
             when ConferenceDay
               "/schedule/day/"
             else
               raise "unsupported class for url(): #{o.class.to_s}"
             end
    prefix + slug(o)
  end

  # Make a link with the appropriate URL type and name
  # depending on the type
  def PentaHelpers.l(obj)
    if obj.is_a? Array
      obj.map{|x| l(x)}.join(", ")
    else
      "<a href=\"#{url(obj)}\">#{name(obj)}</a>"
    end
  end

  # Return the unique identifier, depending on the type
  def PentaHelpers.id(obj)
    a = idattr(obj)
    obj.send(a)
  end

  # Pentabarf uses BlueCloth to convert its text markup in
  # description and abstract into HTML
  def PentaHelpers.markup(text)
    require 'bluecloth'
    BlueCloth.new( text.to_s, :filter_html ).to_html
  end

  # Simple and stupid YAML-safe string escaping to put
  # field values in page metadata sections
  def PentaHelpers.y(o)
    if o.include? ":"
      "! '" + o.gsub(/'/, "''") + "'"
    else
      o
    end
  end

end

# needed to also use helper functions in templates
class Context < Erubis::Context
  def markup(text)
    PentaHelpers::markup(text)
  end
  def idattr(o)
    PentaHelpers::idattr(o)
  end
  def slug(o)
    PentaHelpers::slug(o)
  end
  def name(o)
    PentaHelpers::name(o)
  end
  def url(o)
    PentaHelpers::url(o)
  end
  def l(o)
    PentaHelpers::l(o)
  end
  def id(o)
    PentaHelpers::id(o)
  end
  def y(o)
    PentaHelpers::y(o)
  end
end

class Pentabarf < ::Nanoc::CLI::CommandRunner

  private
  def sha(content)
    require 'digest/sha2'
    sha = Digest::SHA256.new
    sha << content
    sha.hexdigest.downcase
  end

  def render_to(template, target, *bindings)
    time_before = Time.now
    require 'pathname'
    require 'fileutils'

    vars = {}
    bindings.each do |x|
      if x.kind_of? Hash
        x.each{|k,v| vars[k] = v}
      elsif x.kind_of? Array and x.empty?
        # that's fine
      else
        raise "unsupported render flag \"#{x}\""
      end
    end
    tf = File.join("templates", "#{template}.html")
    t = Erubis::Eruby.new(File.read(tf), :filename => tf)

    context = Context.new(vars)
    begin
      output = t.evaluate(context)
    rescue Exception => e
      trace_normalizer = lambda { |line| line.gsub(/^\(erubis\):/, tf + ':') }
      backtrace = e.backtrace.collect(&trace_normalizer)
      message = trace_normalizer.call(e.message)
      raise e.class, message, backtrace
    end

    file = File.join($outdir, "#{target}.html")
    d = Pathname.new(file).dirname.to_s
    FileUtils.mkdir_p(d) unless File.exists?(d)

    action = if File.exists?(file)
               new_digest = sha(output)
               old_digest = sha(IO.read(file))
               if new_digest != old_digest
                 :update
               else
                 :identical
               end
             else
               :create
             end

    unless action == :identical
      File.open(file, "w+") do |f|
        f.write(output)
      end
      duration = Time.now - time_before
      Nanoc::CLI::Logger.instance.file(:high, action, file, duration)
    else
      duration = Time.now - time_before
      Nanoc::CLI::Logger.instance.file(:low, :identical, file, duration)
    end

    $schedule_tree_after << file
  end

  private
  def render(template, *bindings)
    render_to(template, template, bindings)
  end

  public
  def run
    start_time = Time.now

    require_site
    begin
      config = site.config.fetch(:pentabarf)
      $cache = config.fetch(:cache, File.join('tmp', 'pentacache'))
      $cid = config.fetch(:conference_id)
      $outdir = config.fetch(:outdir, File.join('content', 'schedule'))
    end

    # record the filesystem before rendering
    begin
      require 'find'
      $schedule_tree_before = []
      Find.find($outdir) do |f|
        $schedule_tree_before << f unless File.directory? f
      end
    end
    $schedule_tree_after = []

    # define the database model classes
    # :ClassName => cache directory (under $cache/)
    require 'ostruct'
    {
      :Room             => 'conference_room',
      :Event            => 'event',
      :ScheduleEvent    => 'view_schedule_event',
      :Conference       => 'conference',
      :ConferenceDay    => 'conference_day',
      :Track            => 'conference_track',
      :Person           => 'persons',
      :EventPerson      => 'event_persons',
      :ConferencePerson => 'c_persons',
    }.each do |klass, table|
      f = Class.new(OpenStruct) do
      end
      Kernel.const_set klass.to_s, f
      YAML::add_domain_type("pentabarf,0", table) do |type, val|
        f.new(val)
      end
    end

    FileUtils.mkdir_p $outdir

    begin
      puts "Loading Pentabarf cache..."
      time_before = Time.now
      def yl1(klass, file)
        obj = YAML::load_file(file)
        klass.new(obj)
      end
      def yl(klass, dir)
        ld = File.join($cache, dir)
        Dir.entries(ld).reject{|f| File.directory? f}.map{|f| File.join(ld, f)}.map{|f| yl1(klass, f)}
      end

      $conf = yl1(Conference, File.join($cache, 'conf'))
      $days = yl(ConferenceDay, 'days')
      $events = yl(ScheduleEvent, 'events')
      $rooms = yl(Room, 'rooms')
      $tracks = yl(Track, 'tracks')
      $persons = yl(Person, 'persons')
      $event_persons = yl(EventPerson, 'event_persons')
      $conference_persons = yl(ConferencePerson, 'c_persons')
      duration = Time.now - time_before
      Nanoc::CLI::Logger.instance.log(:high, "%s%12s%s  [%2.2fs]  %s" % [ "\e[1m", "cache", "\e[0m", duration, "loaded from #{$cache}" ])
    end

    begin
      time_before = Time.now
      def byid(list, attr)
        result = {}
        list.each {|item| result[item.send(attr)] = item}
        result
      end
      def earr(list, attr)
        result = {}
        list.each {|item| result[item.send(attr)] = []}
        result
      end

      $room_by_id = byid($rooms, :conference_room_id)
      $event_by_id = byid($events, :event_id)
      $track_by_id = byid($tracks, :conference_track_id)
      $person_by_id = byid($persons, :person_id)
      $conference_person_by_person_id = byid($conference_persons, :person_id)

      $room_events = earr($rooms, :conference_room_id)
      $track_events = earr($tracks, :conference_track_id)
      $events.select{|e| e.conference_room_id }.each do |e|
        raise "event #{e.event_id} for room #{e.conference_room_id} that doesn't exist" unless $room_events[e.conference_room_id]
        $room_events[e.conference_room_id] << e
        raise "event #{e.event_id} for track #{e.conference_track_id} that doesn't exist" unless $track_events[e.conference_track_id]
        $track_events[e.conference_track_id] << e
      end

      $event_persons_by_event_id = earr($event_persons, :event_id)
      $event_persons.each{|ep| $event_persons_by_event_id[ep.event_id] << ep}

      speaker_roles = ['coordinator', 'moderator', 'speaker']
      speaker_states = ['confirmed', 'offer']
      $speaker_persons = {}
      $speaker_conference_persons = {}
      $speaker_person_by_id = {}
      $speaker_for = earr($persons, :person_id)
      $event_speakers = earr($events, :event_id)

      $events.each do |e|
        $speaker_persons[e.event_id] = []
        $speaker_conference_persons[e.event_id] = []

        $event_persons_by_event_id.fetch(e.event_id, []).select{|ep| speaker_roles.include? ep.event_role and speaker_states.include? ep.event_role_state }.each do |ep|
          person = $person_by_id.fetch(ep.person_id)
          confperson = $conference_person_by_person_id[ep.person_id]
          $speaker_persons[ep.event_id] << person
          $speaker_conference_persons[ep.event_id] << confperson unless confperson.nil?
          $speaker_person_by_id[person.person_id] = person
          $speaker_for[person.person_id] << e
          $event_speakers[e.event_id] << person
        end
      end

      duration = Time.now - time_before
      Nanoc::CLI::Logger.instance.log(:high, "%s%12s%s  [%2.2fs]  %s" % [ "\e[1m", "cache", "\e[0m", duration, "postprocessed" ])
    end

    begin
      puts "Compiling schedule pages..."

      # and here we do the actual rendering
      # simply render all the templates that end in 's'
      Dir.glob(File.join('templates', '*s.html')).reject{|f| File.directory? f}.each do |template|
        render(Pathname.new(template).basename.to_s.gsub(/\..+$/, ''))
      end

      # render the speakers
      $speaker_person_by_id.values.each do |person|
        confperson = $conference_person_by_person_id[person.person_id]
        events = $speaker_for[person.person_id]
        render_to('speaker', File.join('speaker', PentaHelpers::slug(person)), :p => person, :cp => confperson, :events => events)
      end

      # render the events
      $events.each do |event|
        speakers = $event_speakers.fetch(event.event_id, [])
        render_to('event', File.join('event', PentaHelpers::slug(event)), :e => event, :speakers => speakers)
      end

      $tracks.each do |track|
        events = $track_events[track.conference_track_id]
        render_to('track', File.join('track', PentaHelpers::slug(track)), :t => track, :events => events)
      end

      $rooms.each do |room|
        events = $room_events[room.conference_room_id]
        render_to('room', File.join('room', PentaHelpers::slug(room)), :r => room, :events => events)
      end
    end

    # remove dead files
    begin
      h = {}
      $schedule_tree_after.each{|f| h[f] = 1}
      
      outdated = $schedule_tree_before.sort.reject{|f| h[f]}

      require 'fileutils'
      outdated.each do |f|
        FileUtils.rm f
        Nanoc::CLI::Logger.instance.file(:high, :delete, f)
      end
    end
    
    # now crawl for empty directories and remove those too
    begin
      # let's pack this routine into a function of its own,
      # as we need to reiterate the process (see below)
      def find_empty_dirs(dir)
        list = []
        require 'find'
        Find.find(dir) do |d|
          next unless File.directory? d

          # see http://stackoverflow.com/questions/5059156/check-if-directory-is-empty-in-ruby
          if (Dir.entries(d) - %w{ . .. }).empty?
            list << d
          end
        end
        list
      end

      # we have to iterate until we can't find any empty directories any more,
      # as removing one empty directory can yield other empty directories as
      # empty too
      empty_dirs = find_empty_dirs($outdir)
      until empty_dirs.empty?
        empty_dirs.each do |d|
          require 'fileutils'
          FileUtils.rmdir d
          Nanoc::CLI::Logger.instance.file(:high, :delete, d)
        end
        empty_dirs = find_empty_dirs($outdir)
      end
    end

    puts
    puts "Schedule compiled in #{format('%.2f', Time.now - start_time)}s to #{$outdir}."
  end

end

runner Pentabarf
