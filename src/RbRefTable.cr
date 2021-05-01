module Anyolite
  # This is a very simple approach to generate artificial references to the wrapped objects.
  # Therefore, the GC won't delete the wrapped objects until necessary.
  # Note that this is currently one-directional, so mruby might still delete Crystal objects generated from Crystal itself.
  # Furthermore, this is only possible as a module due to C closure limitations.
  #
  # TODO: Add compilation option for ignoring entry checks
  module RbRefTable
    @@content = {} of UInt64 => Tuple(Void*, Int64)

    @@options = {
      # Log every change in the reference table
      :logging                      => false,
      
      # Display warning messages
      :warnings                     => true,
      
      # Throw an exception if any warning occurs
      :pedantic                     => true,
      
      # If true, values with same object IDs can overwrite each other
      :replace_conflicting_pointers => false,
    }

    def self.get(identification)
      return @@content[identification][0]
    end

    def self.add(identification, value)
      puts "> Added reference #{identification} -> #{value}" if option_active?(:logging)
      if @@content[identification]?
        if value != @@content[identification][0]
          if option_active?(:replace_conflicting_pointers)
            puts "WARNING: Value #{identification} replaced pointers (#{value} vs #{@@content[identification][0]})." if option_active?(:warnings)
            raise "Corrupted reference table" if option_active?(:pedantic)
            @@content[identification] = {value, @@content[identification][1] + 1}
          else
            @@content[identification] = {@@content[identification][0], @@content[identification][1] + 1}
          end
        else
          @@content[identification] = {value, @@content[identification][1] + 1}
        end
      else
        @@content[identification] = {value, 1i64}
      end
    end

    def self.delete(identification)
      puts "> Removed reference #{identification}" if option_active?(:logging)
      if @@content[identification]?
        @@content[identification] = {@@content[identification][0], @@content[identification][1] - 1}
        if @@content[identification][1] <= 0
          @@content.delete(identification)
        end
      else
        puts "WARNING: Tried to remove unregistered object #{identification} from reference table." if option_active?(:warnings)
        raise "Corrupted reference table" if option_active?(:pedantic)
      end
      nil
    end

    def self.is_registered?(identification)
      return @@content[identification]?
    end

    def self.may_delete?(identification)
      @@content[identification][1] <= 1
    end

    def self.inspect
      @@content.inspect
    end

    def self.reset
      if !@@content.empty?
        puts "WARNING: Reference table is not empty (#{@@content.size} elements will be deleted)." if option_active?(:warnings)
        raise "Corrupted reference table" if option_active?(:pedantic)
      end
      @@content.clear
    end

    # TODO: If a struct wrapper is given here, call the struct methods instead of the wrapper methods
    def self.get_object_id(value)
      if value.responds_to?(:rb_ref_id)
        value.rb_ref_id.to_u64
      elsif value.responds_to?(:object_id)
        value.object_id.to_u64
      else
        value.hash.to_u64
      end
    end

    def self.option_active?(symbol)
      if @@options[symbol]?
        @@options[symbol]
      else
        false
      end
    end

    def self.set_option(symbol)
      @@options[symbol] = true
    end

    def self.unset_option(symbol)
      @@options[symbol] = false
    end
  end
end
