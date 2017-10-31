#!/usr/bin/ruby

require 'ruby_dig' if RUBY_VERSION < '2.3'

require 'getoptlong'
require 'snmp'

# 1.3.6.1.2.1.43.10.2.1.4.1.1 gives you a total printed pages

def usage(s)
  $stderr.puts(s)
  $stderr.puts("Usage: #{File.basename($0)}: --printer <ip|fqdn> [--toner <black|cyan|magenta|yellow>] ")
  exit(2)
end

class CheckSamsungPrinter

  STATE_OK        = 0
  STATE_WARNING   = 1
  STATE_CRITICAL  = 2
  STATE_UNKNOWN   = 3
  STATE_DEPENDENT = 4

  COLOR_OID = SNMP::ObjectId.new('1.3.6.1.2.1.43.11.1.1.6')
  MAX_OID   = SNMP::ObjectId.new('1.3.6.1.2.1.43.11.1.1.8')
  CUR_OID   = SNMP::ObjectId.new('1.3.6.1.2.1.43.11.1.1.9')

  def initialize( options = {} )

    @printer = options.dig(:printer)
  end


  def calculate_percent( current, max )

    percent = 100
    percent = current.to_f / max.to_f  * 100 if( current.to_i != 0 )

    { used: 100 - percent.to_i, available: percent.to_i }
  end


  def output( params )

    status  = params.dig(:status)
    message = params.dig(:message)

    message_status = case status
      when STATE_OK
        'OK'
      when STATE_WARNING
        'WARNING'
      when STATE_CRITICAL
        'CRITICAL'
      else
        'UNKNOWN'
    end

    puts format( '%s - %s', message_status,  message )
    exit status
  end


  def snmp_data()

    rows = 12
    toner_array  = []
    hardware_array = []

    SNMP::Manager.open( host: @printer ) do |manager|

      begin
      response = manager.get_bulk( 0, rows, [ COLOR_OID, MAX_OID, CUR_OID ] )
      list     = response.varbind_list

      rescue SNMP::RequestTimeout => e

        output( status: STATE_CRITICAL, message: 'printer not responding' )
      end

      until( list.empty? )

        mib_description = list.shift.value.to_s
        mib_capacity    = list.shift.value.to_i
        mib_available   = list.shift.value.to_i

        percent_used, percent_available  = calculate_percent( mib_available, mib_capacity ).values

        if( mib_description.include?('Toner S/N' ) )

          parts = mib_description.match( '(?<color>.+[a-zA-Z0-9-]) Toner(.*):CRUM-(?<snr>.+[0-9])' )
          descr = mib_description.downcase.split( ' toner s/n' ).first.strip
          serial_number = nil
          descr         = parts['color'].to_s.downcase.strip if( parts )
          serial_number = parts['snr'].to_s.strip if( parts )

          used = mib_capacity - mib_available

          data = { descr => { capacity: mib_capacity, used: used, available: mib_available, percent_used: percent_used, percent_available: percent_available } }
          data[descr]['serial'] = serial_number unless( serial_number.nil? )

          toner_array.push( data )
        else

          data = { mib_description => { capacity: mib_capacity, used: mib_available, percent_used: percent_used } }

          hardware_array.push( data )
        end
      end
    end

    {
      toner: toner_array.flatten,
      hardware: hardware_array.flatten
    }

  end


  def toner( params )

    data     = params.dig(:data)
    toner    = params.dig(:toner)
    warning  = params.dig(:warning)  || 15
    critical = params.dig(:critical) || 10

#     puts params

    unless( data.nil? )

      data.each do |d|

        d = d.select { |x| x == toner.to_s } unless( toner.nil? )

        d.each do |k,v|

          toner_color        = k
          toner_capacity     = v.dig(:capacity)
          toner_used         = v.dig(:used)
          toner_percent_available = v.dig(:percent_available)

          if( toner_percent_available == warning || toner_percent_available >= warning )
            exitCode = STATE_OK
          elsif( toner_percent_available <= warning && toner_percent_available >= critical )
            exitCode = STATE_WARNING
          else
            exitCode = STATE_CRITICAL
          end

          output( status: exitCode, message: format( 'Toner %s - available percent: %s%% (used: %s, capacity: %s)', toner_color, toner_percent_available, toner_used, toner_capacity ) )

        end
      end
    end
  end


  def snmp_dump()

    manager = SNMP::Manager.new(:Host => @printer, :Port => 161)
    start_oid = SNMP::ObjectId.new("1.3.6.1.2.1.43") # 1.3.6.1.2.1.43.10.2.1.4.1.1
    next_oid = start_oid
    while next_oid.subtree_of?(start_oid)
      response = manager.get_next(next_oid)
      varbind = response.varbind_list.first
      # break if EndOfMibView == varbind.value
      next_oid = varbind.name
      puts "#{varbind.name.to_s}  #{varbind.value.to_s}  #{varbind.value.asn1_type}"
    end

  end


  def snmp_if_table()

manager = SNMP::Manager.new(:Host => @printer, :Port => 161)
ifTable = SNMP::ObjectId.new("1.3.6.1.2.1.2.2")
next_oid = ifTable
while next_oid.subtree_of?(ifTable)
  response = manager.get_next(next_oid)
  varbind = response.varbind_list.first
  next_oid = varbind.name
  puts "#{varbind.name.to_s}  #{varbind.value.to_s}  #{varbind.value.asn1_type}"
end


  end


  def snmp_walk

SNMP::Manager.open(:Host => @printer) do |manager|
  manager.walk(["ifIndex", "ifDescr"]) do |ifIndex, ifDescr|
    puts "#{ifIndex} #{ifDescr}"
  end
end


  end

end

# -------------------------------------------------------------------------------------------------

opts = GetoptLong.new(
  [ '--help'    , '-h', GetoptLong::NO_ARGUMENT ],
  [ '--printer' , '-P', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--toner'   ,       GetoptLong::REQUIRED_ARGUMENT ]
)

printer = nil
toner = nil

begin

  opts.quiet = false
  opts.each do |opt, arg|

    case opt
    when '--help'
      usage("Unknown option: #{ARGV[0].inspect}")
    when '--printer'
      printer = arg
    when '--toner'

      whitelist = %w(black cyan magenta yellow)
      toner = arg.downcase unless( arg.nil? )

      unless( whitelist.include?( toner ) )
        usage( "unknown toner: #{toner}" )
      end

    #when '--
    end

  end
rescue => e
  puts "Error in arguments"
  puts e.to_s

  exit 1
end

if( printer.nil? )
  usage( 'missing printer.' )
  exit 1
end

if( toner.nil? )
  usage( 'missing toner.' )
  exit 1
end

# -------------------------------------------------------------------------------------------------

p = CheckSamsungPrinter.new( printer: printer )

m = p.snmp_data

p.toner( data: m.dig(:toner), toner: toner )

# EOF
