class MapReduce
  module File
    attr_accessor :offset, :queue_size, :locked_queue_wait, :empty_queue_wait, :rescan_when_complete, :vigilant, :lines_per_client, :update_file_object_block, :email_file_object
    attr_reader :total

    class Client
      include DRbUndumped

      include Enumerable

      def initialize(server_object)
        @server_object = server_object
      end

      def each
        @server_object.limit.times do
          yield @server_object.get_lines
        end
      end

      def logger(*args)
        @server_object.logger(*args)
      end
    end

    def get_lines
      t = Time.now
      
      lines = []
      (@lines_per_client || 1).times do
        begin
          if @lock
            sleep locked_queue_wait || 1
            retry
          else
            if line = queue.shift
              lines << line
            else
              sleep empty_queue_wait || 30
              retry
            end
          end
        rescue MapReduceError
          retry
        end
      end

      @time_spent_grabbing_objects += (Time.now - t)
      @num_objects_grabbed += 1

      return lines.join, @email_file_object
    end

    private
    
    def set_total
      @total = ::File.size(input)
      @queue_size ||= 1000
    end
    
    def queue
      if @queue.empty?
        case @offset
        when 0
          set_total
        else
          if @offset >= @total
            if @rescan_when_complete || @vigilant
              set_total
            elsif !@update_file_object_block.nil?
              @email_file_object.completed_at = Time.now
              @email_file_object.save
              @new_file_name = ""
              @email_file_object = nil
              begin
                @email_file_object = @update_file_object_block.call
                @new_file_name = @email_file_object.local_file_name unless @email_file_object.nil?
                logger.info Time.now.to_s + " New file: " + @new_file_name unless @new_file_name.blank?
                sleep 15
              end while @new_file_name.blank?
              @input = @new_file_name
              @email_file_object.started_at = Time.now
              @email_file_object.save
              set_total
              @offset = 0
            else
              begin
                self.finished
              rescue NameError
              ensure
                exit
              end
            end
          end
        end

        GC.start

        @time_began = Time.now if @time_began == 0
        @lock = true
        t = Time.now

        file = ::File.open(input)
        file.seek(@offset)
        @queue_size.times do
          @queue << file.gets unless file.pos >= @total
        end
        @queue.compact!
        
        @time_spent_grabbing_queues += (Time.now - t)
        @num_queues_grabbed += 1

        @offset = file.pos unless @queue.empty?
        @offset = 0 if @offset == @total && @rescan_when_complete
        @lock = false
      end

      @queue
    end
  end
end