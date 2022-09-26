#!/usr/bin/env ruby
#
# vim: set ts=4 sw=4 et :

# This is meant to setup xrandr layout by edid substring. For example by monitor
# serial number.
#
# License: GPL v. 2.0, not the latter

require 'pp'

class XRandr
    Output = Struct.new(:name, :edid, :screen)

    # Parse output of `xrandr --prop` (or supplied input) and return array of Outputs
    def self.parse(input = nil)
        input ||= `xrandr --prop`

        outputs = []
        state = :normal
        screen = nil
        current_output = nil
        edid = []

        input.split(/\n/).each do |ln|
            case state
            when :normal
                case ln
                when /^Screen\s+(\d+):.*/
                    screen = $1.to_i
                when /^(\S*?)\s+((dis|)connected|unknown connection)/
                    outputs << current_output unless current_output.nil?
                    current_output = Output.new($1, nil, screen)
                when /^\s*EDID:\s*/
                    state = :edid
                    edid = []
                else
                    # props... don't care
                end
            when :edid
                if ln =~ /^\s*([0-9a-f]+)\s*$/
                    edid << $1
                else
                    state = :normal
                    current_output.edid = edid.join
                end
            end
        end
        outputs << current_output unless current_output.nil?
        outputs
    end

    # For raw hex encoded edid, return human readable strings
    def self.humanize_edid(edid)
        if edid
            edid.scan(/../).map { |x|
                n=x.to_i(16);
                (32..126).include?(n) ? n.chr : "\x0"
            }.join.scan(/[\w_-]{3,}/).join(' ')
        else
            "*** no edid ***"
        end
    rescue Object
        "*** unknown edid (exception when parsing) ***"
    end

    # Return current xrandr config for given output. Requires unxrandr to work.
    def self.current_config(output)
        layout = `unxrandr` rescue nil
        if layout.nil?
            "unknown (need 'unxrandr' installed)"
        else
            re = Regexp.new("\\s*--output\\s+#{output}\\s+") # nice work, vim ft=ruby
            layout = layout.split(/(?=--output)|$/).grep(re)
            if layout.size > 0
                layout.first.sub(re, '')
            else
                "unknown (couldn't parse unxrandr)"
            end
        end
    rescue Object
        "unknown (exception when parsing)"
    end

    # Return xrandr config string for given config and (optionally) input
    def self.config_string_for(display_configs, default_config = "--off",
                               must_match_all = false, input = nil)
        to_match = display_configs.keys

        configs = self.parse(input).map do |output|
            edid = output.edid || ""
            serial, conf = display_configs.find { |s, _|
                edid.index(s.to_s.chars.map { |x| "%02x" % x.ord }.join) }
            if serial
                to_match.delete(serial)
                if $VERBOSE
                    STDERR.puts "Matched #{output.name} @ #{output.screen} to #{serial}."
                end
            else
                if $VERBOSE
                    STDERR.puts "Couldn't match #{output.name} to any serial."
                    STDERR.puts "  EDID strings: #{self.humanize_edid(output.edid)}"
                    STDERR.puts "  current config: #{self.current_config(output.name)}"
                end
            end
            ["--output", output.name, conf || default_config]
        end.flatten

        if must_match_all && !to_match.empty?
            raise "Failed to match serial(s) '#{to_match.join(' ')}' to an output."
        end

        configs
    end
end

if __FILE__ == $0
    require 'optparse'
    options = {
        configs: {},
        default_config: %w[--off],
        prefix: %w[],
        match_all: false,
    }

    op = OptionParser.new do |opts|
        opts.banner = "Usage: #{File.basename($0)} [options]"
        opts.separator 'Available options:'

        opts.on("-sSERIAL", "--serial=SERIAL", String,
                "Serial of an output for which --config follows") do |s|
            options[:serial] = s
        end

        opts.on("-cCONFIG", "--config=CONFIG", String,
                "Config for output with previously specified serial") do |c|
            unless options[:serial]
                raise OptionParser::InvalidArgument, "no serial given so far"
            end
            s = options[:serial]
            options[:configs][s] ||= c.split(/\s+/)
        end

        opts.on("-dCONFIG", "--default-config=CONFIG", String,
                "Default config for non-matching outputs, by default --off.") do |dc|
            options[:default_config] = dc.split(/\s+/)
        end

        opts.on("-pCONFIG", "--prefix=CONFIG", String,
                "Prefix config before any outputs, by default empty.") do |pfx|
            options[:prefix] = pfx.split(/\s+/)
        end

        opts.on("-a", "--[no-]all-or-abort",
                "Match all configured or abort, by default false.") do |match_all|
            options[:match_all] = match_all
        end

        opts.on("-v", "--[no-]verbose", "Verbose operation.") do |verbose|
            $VERBOSE = verbose
        end

        opts.on("-n", "--dry-run", "Dry run. Evaluate, don't apply.") do |dry_run|
            options[:dry_run] = dry_run
        end
    end

    begin
        op.parse!(ARGV)
    rescue OptionParser::InvalidOption
        STDERR.puts "Error: invalid option: #{$!}"
        exit 1
    rescue OptionParser::InvalidArgument
        STDERR.puts "Error: invalid argument: #{$!.args.join(' ')}"
        exit 1
    rescue OptionParser::NeedlessArgument
        STDERR.puts "Error: needless argument for a bool flag: #{$!.args.join(' ')}"
        exit 1
    end

    if options[:configs].empty? && !options[:dry_run]
        STDERR.puts "No config specified, forcing verbose (for debug) and dry" + 
            " run (to avoid killing your X session)."
        options[:dry_run] = true
        $VERBOSE = true
    end

    if $VERBOSE
        STDERR.puts "Parsed config:"
        PP.pp(options, STDERR)
    end

    config = nil
    begin
        config = XRandr.config_string_for(options[:configs],
                                          options[:default_config],
                                          options[:match_all])
    rescue
        STDERR.puts "Error: #$! (all serials: #{options[:configs].keys.join(', ')})"
        exit 1
    end

    config = options[:prefix] + config

    if options[:dry_run]
        puts "# dry run mode, would run:"
        puts "xrandr #{config.join(' ')}"
        exit 0
    else
        if $VERBOSE
            STDERR.puts "Running xrandr with:"
            PP.pp(config, STDERR)
        end

        system("xrandr", *config)
        exit $?.exitstatus
    end
end
