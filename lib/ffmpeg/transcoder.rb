require 'open3'
require 'shellwords'

module FFMPEG
  class Transcoder
    @@timeout = 300

    def self.timeout=(time)
      @@timeout = time
    end

    def self.timeout
      @@timeout
    end

    def initialize(movie, output_file, options = EncodingOptions.new, transcoder_options = {})
      @movie = movie
      @output_file = output_file

      if options.is_a?(String) || options.is_a?(EncodingOptions)
        @raw_options = options
      elsif options.is_a?(Hash)
        @raw_options = EncodingOptions.new(options, movie)
      else
        raise ArgumentError, "Unknown options format '#{options.class}', should be either EncodingOptions, Hash or String."
      end

      @transcoder_options = transcoder_options
      @errors = []

      apply_transcoder_options
    end

    def run(&block)
      transcode_movie(&block)
      if @transcoder_options[:validate]
        validate_output_file(&block)
        return (creating_thumbnails? ? true : encoded)
      else
        return nil
      end
    end

    def encoding_succeeded?
      paths = thumbnails_paths || Array[@output_file]
      paths.each do |path|
        @errors << "no output file created" and return false unless File.exists?(path)
      end
      unless creating_thumbnails?
        @errors << "encoded file is invalid" and return false unless encoded.valid?
      end
      true
    end

    def encoded
      @encoded ||= Movie.new(@output_file)
    end

    private

    def creating_thumbnails?
      @raw_options[:thumbnails]
    end

    def thumbnails_paths
      count = @raw_options[:thumbnails].try(:[], :count)
      paths = (1..count).map{|i| @output_file % i} if count
    end

    # frame= 4855 fps= 46 q=31.0 size=   45306kB time=00:02:42.28 bitrate=2287.0kbits/
    def transcode_movie
      priority      = @transcoder_options.try(:[], :priority) || 0

      if FFMPEG.cp_mode
        if @output_file == '/dev/null'
            @command = "cp ./features/data/example.log-0.log #{Shellwords.escape("#{File.dirname(@movie.path)}/hds_preprocessing.log-0.log")}
                     && cp ./features/data/example.log-0.log.mbtree #{Shellwords.escape("#{File.dirname(@movie.path)}/hds_preprocessing.log-0.log.mbtree")}"
          else
            @command = "cp ./features/data/example#{File.extname(@output_file)} #{@output_file}"
        end
      else
        @command = "nice -n #{priority} #{FFMPEG.ffmpeg_binary} -y -i #{Shellwords.escape(@movie.path)} #{@raw_options} #{Shellwords.escape(@output_file)}#{' || exit 1' if @transcoder_options.try(:[], :or_exit)}"
        @command = "#{@command} && #{FFMPEG.qtfaststart_binary} #{Shellwords.escape(@output_file)}" if @transcoder_options.try(:[], :meta_2_begin)
      end

      FFMPEG.logger.info("Running transcoding...\n#{@command}\n")
      @output = ''

      # raise @command

      Open3.popen3(@command) do |stdin, stdout, stderr, wait_thr|
        begin
          yield(0.0) if block_given?
          next_line = Proc.new do |line|
            fix_encoding(line)
            @output << line
            if line.include?("time=")
              if line =~ /time=(\d+):(\d+):(\d+.\d+)/ # ffmpeg 0.8 and above style
                time = ($1.to_i * 3600) + ($2.to_i * 60) + $3.to_f
              else # better make sure it wont blow up in case of unexpected output
                time = 0.0
              end
              progress = time / @movie.duration
              yield(progress) if block_given?
            end
          end

          if @@timeout
            stderr.each_with_timeout(wait_thr.pid, @@timeout, 'size=', &next_line)
          else
            stderr.each('size=', &next_line)
          end

        rescue Timeout::Error => e
          FFMPEG.logger.error "Process hung...\n@command\n#{@command}\nOutput\n#{@output}\n"
          raise Error, "Process hung. Full output: #{@output}"
        end
      end
    end

    def validate_output_file(&block)
      if encoding_succeeded?
        yield(1.0) if block_given?
        FFMPEG.logger.info "Transcoding of #{@movie.path} to #{@output_file} succeeded\n"
      else
        errors = "Errors: #{@errors.join(", ")}. "
        FFMPEG.logger.error "Failed encoding...\n#{@command}\n\n#{@output}\n#{errors}\n"
        raise Error, "Failed encoding.#{errors}Full output: #{@output}"
      end
    end

    def apply_transcoder_options

       # if true runs #validate_output_file
      @transcoder_options[:validate] = @transcoder_options.fetch(:validate) { true }

      return if @movie.calculated_aspect_ratio.nil?
      case @transcoder_options[:preserve_aspect_ratio].to_s
      when ['width', 'video']
        new_height = @raw_options.width / @movie.calculated_aspect_ratio
        new_height = new_height.ceil.even? ? new_height.ceil : new_height.floor
        new_height += 1 if new_height.odd? # needed if new_height ended up with no decimals in the first place
        @raw_options[:resolution] = "#{@raw_options.width}x#{new_height}"
      when ['height', 'video']
        new_width = @raw_options.height * @movie.calculated_aspect_ratio
        new_width = new_width.ceil.even? ? new_width.ceil : new_width.floor
        new_width += 1 if new_width.odd?
        @raw_options[:resolution] = "#{new_width}x#{@raw_options.height}"
      when ['height', 'screenshot']
      when ['width', 'screenshot']
      end
    end

    def fix_encoding(output)
      output[/test/]
    rescue ArgumentError
      output.force_encoding("ISO-8859-1")
    end
  end
end
