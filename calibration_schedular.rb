#!/usr/bin/env ruby

require 'time'
require 'elasticsearch'
require 'pi_piper'

Thread.abort_on_exception = true

#Generating elasticsearch index
es = Elasticsearch::Client.new url: ARGV[0]
index_exists = es.indices.exists index: "motortest-project-index"
if !index_exists
puts "Index \"motortest-project-index\" does not exist. Creating..."
es.indices.create index: "motortest-project-index",
    body: {
        settings: {
            number_of_shards: 1
        },
        mappings: {
            sensor_data: {
                properties: {
                    timestamp: {
                        type: 'date',
                        format: 'epoch_millis',
                        index: 'not_analyzed'
                    },
                    sensor_number: {
                        type: 'integer',
                        index: 'not_analyzed',
                        fields: {
                            raw: {
                                type: 'keyword'
                            }
                        }
                    },
                    value: {
                        type: 'double',
                        index: 'not_analyzed',
                        fields: {
                            raw: {
                                type: 'keyword'
                            }
                        }
                    },
                }
            }
        }
    }, wait_for_active_shards: 1
puts "Index created."
end
puts "Generating data now."

#Threading Sensor readings

sensorthreads = Array.new
flowrate = Array.new
flowsensor_on = true
running = true

(0..0).each do |i|
  sensorthreads[i] = Thread.new do
        while flowsensor_on do
            value = 0
            PiPiper::Spi.begin do |spi|
              raw = spi.write [1, (8 + i) << 4, 0]
              value = ((raw[1] & 3) << 8) + raw[2]
             # puts "The flowrate value is #{value}"
            end
            flowrate[i] = value * 500 / 1023
           # puts "Flowrate for thread #{i} = #{flowrate[i]}"
      # Generating sensor
      next if value ==0
    es.index index: 'motortest-project-index',
          type: 'sensor_data',
          body: {
              timestamp: (Time.now.to_f * 1000.0).to_i,
              sensor_number: i,
              value: flowrate[i]
                }
            sleep(0.2)
      end
  end
end


# Calibration loop
count = 0
tot = 0
average = 0
variance = 0
stdev = 0
calibrationon=true
while calibrationon do

  reading = flowrate[0]
  next if reading.nil?
  next if reading ==0
  # start accumulating an average for proof that
  # we are, in fact, getting consistent flow...
  #
  # we'll use the average to seed our high/low calculations next
 # if count >= 0  && count <= 100 
    until count >= 5000 do
    if reading >0 
     count += 1
    tot += reading
    average = tot/count
    variance = (reading-average)**2/count
    stdev = Math.sqrt(variance)
   # puts "Flow began... average at #{average} count is #{count}"

 # else
  #  puts "Awaiting flow or sensor read incorrectly..."
   # next
 # end
  if count == 1000
    puts "Calibrated after 1000 readings...average at #{average} finding systol/diastol cycles..."
  end
  if count >= 1000 and count < 2000
   # set up some counters to track what the
    # highest throughput (potential systol) and
    # lowest throughput(potential diastol)  we have seen are
    highest ||= [average.to_i]
    lowest ||= [average.to_i]
    avg_systol = highest.reduce(:+) / highest.size
    avg_diastol = lowest.reduce(:+) / lowest.size
    # Do the actual comparison per loop maybe make it the average
   
    if reading > avg_systol && stdev < 3 && stdev > -3
      highest.push(reading)
      puts "New high of #{highest} found."
    elsif reading < avg_diastol  && stdev <3 && stdev >-3
      lowest.push(reading)
      puts "New low of #{lowest} found."
    end
  end
  if count == 2000
  puts "Count is #{count}"
    # Keep the end users busy with some shiny TEXTTT!!!!
    avg_systol = highest.reduce(:+) / highest.size
    avg_diastol = lowest.reduce(:+) / lowest.size
    puts "Proceeding with presumed systol of #{avg_systol} and presumed diastol of #{avg_diastol}..."
  end
  if count >=2000 && count <4000
    # set up our variables if needed
    systol_duration_total ||= 0
    systol_count ||= 0
    diastol_duration_total ||= 0
    diastol_count ||= 0
    systol_timestamp ||= nil
    diastol_timestamp ||= nil
    state ||= :none

    # figure out if we are nearest to systol (highest) or diastol (lowest)
    diff_to_systol = (avg_systol - reading).abs
    diff_to_diastol = (avg_diastol - reading).abs
    if diff_to_systol > diff_to_diastol
      puts "Reading is in diastol range..."
      # we are diastol!!!
      case state
      when :none
        # we were not running and this is our first time.
        # let's get a timestamp and remember it for later... :)
        diastol_timestamp = DateTime.now
      when :diastol
        # we are _still_ diastol and waiting for the damn pump to switch back over
      when :systol
        # uh-oh!!! this is a time when we have just changed from systol to diastol...
        # let's remember this event too... :)
        diastol_timestamp = DateTime.now
        if !systol_timestamp.nil?
          systol_duration_total += (diastol_timestamp.to_time.to_f - systol_timestamp.to_time.to_f)
          systol_count += 1
        end
      end
      state = :diastol
    else
      puts "Reading is in systol range..."
      # we are systol!!!
      case state
      when :none
        # looks like we started out as systol for the first time.  Coolio :)
        # let's write this down...
        systol_timestamp = DateTime.now
      when :diastol
        # we have freshly changed over from diastol to systol.  This is an event to be remembered.
        systol_timestamp = DateTime.now
        if !diastol_timestamp.nil?
          diastol_duration_total += (systol_timestamp.to_time.to_f - diastol_timestamp.to_time.to_f)
          diastol_count += 1
        end
      when :systol
        # we are still in systol
      end
      state = :systol
    end
    puts "Average systol duration at #{systol_duration_total.to_f / systol_count}s" if systol_count > 0
    puts "Average diastol duration at #{diastol_duration_total.to_f / diastol_count}s" if diastol_count > 0
  end
  if count >=4000
    diff_to_systol = (avg_systol - reading).abs
    diff_to_diastol = (avg_diastol - reading).abs
    if diff_to_systol > diff_to_diastol
      case state
      when :diastol
        # we are _still_ diastol and waiting for the damn pump to switch back over
      when :systol
        # it switched!!! time to kick into scheduled mode!!!
        break
      end
    else
      case state
      when :diastol
        # it switched!!! time to kick into scheduled mode!!!
        break
      when :systol
        # we are _still_ systol and waiting for the damn pump to switch back over
      end
    end
  end
  
end
end
calibrationon = false 
end 

# Scheduled mode!!!
while !calibrationon do
  if state == :diastol
    puts "Flipping to diastol..."
    sleep (diastol_duration_total.to_f / diastol_count)
    state = :systol
  elsif state == :systol
    puts "Flipping to systol..."
    sleep (systol_duration_total.to_f / systol_count)
    state = :diastol
  end
end
