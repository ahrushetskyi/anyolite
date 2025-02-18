require "./RbInternal.cr"

require "./RbInterpreter.cr"
require "./RbClass.cr"
require "./RbCast.cr"
require "./Macro.cr"
require "./RbClassCache.cr"
require "./RbTypeCache.cr"
require "./RbModule.cr"
require "./RbRefTable.cr"
require "./RbArgCache.cr"
require "./Preloader.cr"

# Main wrapper module, which should be covering most of the use cases.
module Anyolite
  # Special struct representing undefined values in mruby.
  struct Undefined
    # :nodoc:
    def initialize
    end
  end

  # Use this special constant in case of a function to wrap, which has only an operator as a name.
  struct Empty
    # :nodoc:
    def initialize
    end
  end

  # Internal class to hide the `Struct` *T* in a special class
  # to obtain all class-related properties.
  class StructWrapper(T)
    @content : T | Nil = nil

    def initialize(value)
      @content = value
    end

    def content : T
      if c = @content
        c
      else
        # This should not be called theoretically
        raise("Content of struct wrapper for #{T} is undefined!")
      end
    end

    def content=(value)
      @content = value
    end
  end

  # Class to contain Ruby values in a GC-protected container
  class RbRef
    @value : RbCore::RbValue

    # Create a new container with *value* as content
    def initialize(value : RbCore::RbValue)
      @value = value
      RbCore.rb_gc_register(RbRefTable.get_current_interpreter, value)
    end

    # Return the contained value
    def value
      @value
    end

    # Return `true` if the value is undefined, otherwise `false`
    def is_undef?
      RbCast.check_for_undef(@value)
    end

    # Return `true` if the value is a Ruby bool, otherwise `false`
    def is_bool?
      RbCast.check_for_bool(@value)
    end

    # Return `true` if the value is a Ruby nil, otherwise `false`
    def is_nil?
      RbCast.check_for_nil(@value)
    end

    # Return `true` if the value is a Ruby fixnum, otherwise `false`
    def is_fixnum?
      RbCast.check_for_fixnum(@value)
    end

    # Return `true` if the value is a Ruby float, otherwise `false`
    def is_float?
      RbCast.check_for_float(@value)
    end

    # Return `true` if the value is a Ruby string, otherwise `false`
    def is_string?
      RbCast.check_for_string(@value)
    end

    # Return `true` if the value is a Ruby symbol, otherwise `false`
    def is_symbol?
      RbCast.check_for_symbol(@value)
    end

    # Return `true` if the value is a Ruby array, otherwise `false`
    def is_array?
      RbCast.check_for_array(@value)
    end

    # Return `true` if the value is a Ruby hash, otherwise `false`
    def is_hash?
      RbCast.check_for_hash(@value)
    end

    # Return `true` if the value is a wrapped objects, otherwise `false`
    def is_custom?
      RbCast.check_for_data(@value)
    end

    # Return `true` if the value is a wrapped object of class *class_name*, otherwise `false`
    def is_custom?(class_name)
      RbCast.check_custom_type(RbRefTable.get_current_interpreter, value, class_name)
    end

    # :nodoc:
    def finalize
      RbCore.rb_gc_unregister(RbRefTable.get_current_interpreter, value) if RbRefTable.check_interpreter
    end

    # :nodoc:
    def to_unsafe
      @value
    end
  end

  # Undefined mruby value.
  Undef = Undefined.new

  # Returns the current implementation (either `:mruby` or `:mri`) as a `Symbol`.
  macro implementation
    {% if flag?(:anyolite_implementation_ruby_3) %}
      :mri
    {% else %}
      :mruby
    {% end %}
  end

  # Checks whether *value* is referenced in the current reference table.
  macro referenced_in_ruby?(value)
    !!Anyolite::RbRefTable.is_registered?(Anyolite::RbRefTable.get_object_id({{value}}))
  end

  # Returns the `RbValue` of the `Class` or `Module` *crystal_class*.
  macro get_rb_class_obj_of(crystal_class)
    Anyolite::RbCore.get_rb_obj_value(Anyolite::RbClassCache.get({{crystal_class}}))
  end

  # Returns a cached block argument (or `nil`, if none given) in form of a `RbRef`, if enabled.
  # Otherwise, an error will be triggered.
  macro obtain_given_rb_block
    %rb = Anyolite::RbRefTable.get_current_interpreter

    if %bc = Anyolite::RbArgCache.get_block_cache
      if Anyolite::RbCast.check_for_nil(%bc.value)
        nil
      else
        %bc_ref = Anyolite::RbRef.new(%bc.value)
        %bc_ref
      end
    else
      raise "This method does not accept block arguments."
    end
  end

  # Calls the Ruby block *block_value*, given as a `RbRef`, with the arguments *args*
  # as an `Array` of castable Crystal values (`nil` for none).
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro call_rb_block(block_value, args = nil, cast_to = nil, context = nil)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    {% options = {:context => context} %}

    if %rb_block = {{block_value}}
      {% if args %}
        %argc = {{args}}.size
        %argv = Pointer(Anyolite::RbCore::RbValue).malloc(size: %argc) do |i|
          Anyolite::RbCast.return_value(%rb.to_unsafe, {{args}}[i])
        end

        %block_return_value = Anyolite::RbCore.rb_call_block_with_args(%rb, %rb_block.value, %argc, %argv)
      {% else %}
        %block_return_value = Anyolite::RbCore.rb_call_block(%rb, %rb_block.value, Anyolite::RbCast.return_nil)
      {% end %}

      {% if cast_to %}
        Anyolite::Macro.convert_from_ruby_to_crystal(%rb.to_unsafe, %block_return_value, {{cast_to}}, options: {{options}})
      {% else %}
        Anyolite::RbRef.new(%block_return_value)
      {% end %}
    else
      raise "Empty block argument."
    end
  end

  # Casts the `RbRef` *rbref* to the Crystal `Class` *cast_type*.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro cast_to_crystal(rbref, cast_type, context = nil)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    {% options = {:context => context} %}

    Anyolite::Macro.convert_from_ruby_to_crystal(%rb.to_unsafe, {{rbref}}.value, {{cast_type}}, options: {{options}})
  end

  # Raises a Ruby runtime error with `String` *message*.
  macro raise_runtime_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_runtime_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Raises a Ruby type error with `String` *message*.
  macro raise_type_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_type_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Raises a Ruby argument error with `String` *message*.
  macro raise_argument_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_argument_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Raises a Ruby index error with `String` *message*.
  macro raise_index_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_index_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Raises a Ruby range error with `String` *message*.
  macro raise_range_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_range_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Raises a Ruby name error with `String` *message*.
  macro raise_name_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_name_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Raises a Ruby script error with `String` *message*.
  macro raise_script_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_script_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Raises a Ruby non-implementation error with `String` *message*.
  macro raise_not_implemented_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_not_implemented_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Raises a Ruby key error with `String` *message*.
  macro raise_key_error(message)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbCore.rb_raise_key_error(%rb.to_unsafe, {{message}}.to_unsafe)
  end

  # Checks whether the Ruby function *name* (`String` or `Symbol`) is defined
  # for the Crystal object *value*.
  macro does_obj_respond_to(value, name)
    if !{{name}}.is_a?(Symbol) && !{{name}}.is_a?(String)
      raise "Given name {{name}} is neither a String nor a Symbol."
    end

    %rb = Anyolite::RbRefTable.get_current_interpreter
    %obj = {{value}}.is_a?(Anyolite::RbCore::RbValue) || {{value}}.is_a?(Anyolite::RbRef) ? {{value}} : Anyolite::RbCast.return_value(%rb.to_unsafe, {{value}})
    %name = Anyolite::RbCore.convert_to_rb_sym(%rb, {{name}}.to_s)

    Anyolite::RbCore.rb_respond_to(%rb, %obj, %name) == 0 ? false : true
  end

  # Checks whether the Ruby function *name* (`String` or `Symbol`) is defined
  # for the Crystal `Class` or `Module` *crystal_class*.
  macro does_class_respond_to(crystal_class, name)
    if !{{name}}.is_a?(Symbol) && !{{name}}.is_a?(String)
      raise "Given name {{name}} is neither a String nor a Symbol."
    end

    %rb = Anyolite::RbRefTable.get_current_interpreter
    %rb_class = Anyolite.get_rb_class_obj_of({{crystal_class}})
    %name = Anyolite::RbCore.convert_to_rb_sym(%rb, {{name}}.to_s)

    Anyolite::RbCore.rb_respond_to(%rb, %rb_class, %name) == 0 ? false : true
  end

  # TODO: Is it possible to add block args to the two methods below?

  # Calls the Ruby method with `String` or `Symbol` *name* for the Crystal object *value* and the
  # arguments *args* as an `Array` of castable Crystal values (`nil` for none).
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro call_rb_method_of_object(value, name, args, cast_to = nil, context = nil)
    if !{{name}}.is_a?(Symbol) && !{{name}}.is_a?(String)
      raise "Given name {{name}} is neither a String nor a Symbol."
    end
    
    %rb = Anyolite::RbRefTable.get_current_interpreter
    %obj = {{value}}.is_a?(Anyolite::RbCore::RbValue) || {{value}}.is_a?(Anyolite::RbRef) ? {{value}} : Anyolite::RbCast.return_value(%rb.to_unsafe, {{value}})
    %name = Anyolite::RbCore.convert_to_rb_sym(%rb, {{name}}.to_s)

    {% options = {:context => context} %}

    {% if args %}
      %argc = {{args}}.size
      %argv = Pointer(Anyolite::RbCore::RbValue).malloc(size: %argc) do |i|
        Anyolite::RbCast.return_value(%rb.to_unsafe, {{args}}[i])
      end
    {% else %}
      %argc = 0
      %argv = [] of Anyolite::RbCore::RbValue
    {% end %}

    %call_result = Anyolite::RbCore.rb_funcall_argv(%rb, %obj, %name, %argc, %argv)
    
    {% if cast_to %}
      Anyolite::Macro.convert_from_ruby_to_crystal(%rb.to_unsafe, %call_result, {{cast_to}}, options: {{options}})
    {% else %}
      Anyolite::RbRef.new(%call_result)
    {% end %}
  end

  # Calls the Ruby method with `String` or `Symbol` *name* for `self` and the
  # arguments *args* as an `Array` of castable Crystal values (`nil` for none).
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro call_rb_method(name, args = nil, cast_to = nil, context = nil)
    Anyolite.call_rb_method_of_object(self, {{name}}, {{args}}, cast_to: {{cast_to}}, context: {{context}})
  end

  # Calls the Ruby method with `String` or `Symbol` *name* for `self.class` and the
  # arguments *args* as an `Array` of castable Crystal values (`nil` for none).
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro call_rb_class_method(name, args = nil, cast_to = nil, context = nil)
    Anyolite.call_rb_method_of_class(self.class, {{name}}, {{args}}, cast_to: {{cast_to}}, context: {{context}})
  end

  # Calls the Ruby method with `String` or `Symbol` *name*
  # for the Crystal `Class` or `Module` *crystal_class* and the
  # arguments *args* as an `Array` of castable Crystal values (`nil` for none).
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro call_rb_method_of_class(crystal_class, name, args = nil, cast_to = nil, context = nil)
    %rb_class = Anyolite.get_rb_class_obj_of({{crystal_class}})
    Anyolite.call_rb_method_of_object(%rb_class, {{name}}, {{args}}, cast_to: {{cast_to}}, context: {{context}})
  end

  # Calls the Ruby expression *str*.
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro eval(str, cast_to = nil, context = nil)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    {% options = {:context => context} %}

    %call_result = %rb.execute_script_line({{str}})
    
    {% if cast_to %}
      Anyolite::Macro.convert_from_ruby_to_crystal(%rb.to_unsafe, %call_result, {{cast_to}}, options: {{options}})
    {% else %}
      Anyolite::RbRef.new(%call_result)
    {% end %}
  end

  # Returns current object as a `RbRef`
  macro self_in_rb
    %rb = Anyolite::RbRefTable.get_current_interpreter
    Anyolite::RbRef.new(Anyolite::RbCast.return_value(%rb.to_unsafe, self))
  end

  # Gets the Ruby instance variable with `String` or `Symbol` *name* for the Crystal object *object*.
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro get_iv(object, name, cast_to = nil, context = nil)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    %obj = {{object}}.is_a?(Anyolite::RbCore::RbValue) || {{object}}.is_a?(Anyolite::RbRef) ? {{object}} : Anyolite::RbCast.return_value(%rb.to_unsafe, {{object}})
    %name = Anyolite::RbCore.convert_to_rb_sym(%rb, {{name}}.to_s)

    {% options = {:context => context} %}

    %result = Anyolite::RbCore.rb_iv_get(%rb, %obj, %name)

    {% if cast_to %}
      Anyolite::Macro.convert_from_ruby_to_crystal(%rb.to_unsafe, %result, {{cast_to}}, options: {{options}})
    {% else %}
      Anyolite::RbRef.new(%result)
    {% end %}
  end

  # Sets the Ruby instance variable with `String` or `Symbol` *name* for the Crystal object *object*
  # to the Crystal value *value*.
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro set_iv(object, name, value)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    %obj = {{object}}.is_a?(Anyolite::RbCore::RbValue) || {{object}}.is_a?(Anyolite::RbRef) ? {{object}} : Anyolite::RbCast.return_value(%rb.to_unsafe, {{object}})
    %name = Anyolite::RbCore.convert_to_rb_sym(%rb, {{name}}.to_s)
    %value = Anyolite::RbCast.return_value(%rb.to_unsafe, {{value}})

    Anyolite::RbCore.rb_iv_set(%rb, %obj, %name, %value)
  end

  # Gets the Ruby class variable with `String` or `Symbol` *name* for the Crystal `Class` or `Module` *crystal_class*.
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro get_cv(crystal_class, name, cast_to = nil, context = nil)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    %rb_class = Anyolite.get_rb_class_obj_of({{crystal_class}})
    %name = Anyolite::RbCore.convert_to_rb_sym(%rb, {{name}}.to_s)

    {% options = {:context => context} %}

    %result = Anyolite::RbCore.rb_cv_get(%rb, %rb_class, %name)

    {% if cast_to %}
      Anyolite::Macro.convert_from_ruby_to_crystal(%rb.to_unsafe, %result, {{cast_to}}, options: {{options}})
    {% else %}
      Anyolite::RbRef.new(%result)
    {% end %}
  end

  # Sets the Ruby class variable with `String` or `Symbol` *name* for the Crystal `Class` or `Module` *crystal_class*
  # to the value *value*.
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro set_cv(crystal_class, name, value)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    %rb_class = Anyolite.get_rb_class_obj_of({{crystal_class}})
    %name = Anyolite::RbCore.convert_to_rb_sym(%rb, {{name}}.to_s)
    %value = Anyolite::RbCast.return_value(%rb.to_unsafe, {{value}})

    Anyolite::RbCore.rb_cv_set(%rb, %rb_class, %name, %value)
  end

  # Gets the Ruby global variable with `String` or `Symbol` *name*.
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro get_gv(name, cast_to = nil, context = nil)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    {% options = {:context => context} %}

    %result = Anyolite::RbCore.rb_gv_get(%rb, {{name}}.to_s)

    {% if cast_to %}
      Anyolite::Macro.convert_from_ruby_to_crystal(%rb.to_unsafe, %result, {{cast_to}}, options: {{options}})
    {% else %}
      Anyolite::RbRef.new(%result)
    {% end %}
  end

  # Sets the Ruby global variable with `String` or `Symbol` *name*
  # to the Crystal value *value*.
  #
  # If *cast_to* is set to a `Class` or similar, it will automatically cast
  # the result to a Crystal value of that class, otherwise, it will return
  # a `RbRef` value containing the result.
  #
  # If needed, *context* can be set to a `Path` in order to specify *cast_to*.
  macro set_gv(name, value)
    %rb = Anyolite::RbRefTable.get_current_interpreter
    %value = Anyolite::RbCast.return_value(%rb.to_unsafe, {{value}})

    Anyolite::RbCore.rb_gv_set(%rb, {{name}}.to_s, %value)
  end

  # Wraps a Crystal class directly into an mruby class.
  #
  # The Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with *name* as its new designation, returning an `Anyolite::RbClass`.
  #
  # To inherit from another mruby class, specify an `Anyolite::RbClass` as a *superclass*.
  #
  # Each class can be defined in a specifiy module by setting *under* to a `Anyolite::RbModule`.
  macro wrap_class(rb_interpreter, crystal_class, name, under = nil, superclass = nil)
    %new_class = Anyolite::RbClass.new({{rb_interpreter}}, {{name}}, under: Anyolite::RbClassCache.get({{under}}), superclass: Anyolite::RbClassCache.get({{superclass}}))
    Anyolite::RbCore.set_instance_tt_as_data(%new_class)
    Anyolite::RbClassCache.register({{crystal_class}}, %new_class)
    Anyolite::RbClassCache.get({{crystal_class}})
  end

  # Wraps a Crystal module into an mruby module.
  #
  # The module *crystal_module* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with *name* as its new designation, returning an `Anyolite::RbModule`.
  #
  # The parent module can be specified with the module argument *under*.
  macro wrap_module(rb_interpreter, crystal_module, name, under = nil)
    %new_module = Anyolite::RbModule.new({{rb_interpreter}}, {{name}}, under: Anyolite::RbClassCache.get({{under}}))
    Anyolite::RbClassCache.register({{crystal_module}}, %new_module)
    Anyolite::RbClassCache.get({{crystal_module}})
  end

  # Wraps the constructor of a Crystal class into mruby.
  #
  # The constructor for the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the arguments *proc_args* as an `Array of Class`.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  #
  # The arguments *block_arg_number* and *block_return_type* can be set to an `Int` and a `Class`,
  # respectively, in order to require a block argument. If *store_block_arg* is set to `true`,
  # any block argument given will be stored in a cache.
  macro wrap_constructor(rb_interpreter, crystal_class, proc_args = nil, operator = "", context = nil, block_arg_number = nil, block_return_type = nil, store_block_arg = false)
    {%
      options = {
        :context           => context,
        :block_arg_number  => block_arg_number,
        :block_return_type => block_return_type,
        :store_block_arg   => store_block_arg,
      }
    %}
    Anyolite::Macro.wrap_constructor_function_with_args({{rb_interpreter}}, {{crystal_class}}, {{crystal_class}}.new, {{proc_args}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps the constructor of a Crystal class into mruby, using keyword arguments.
  #
  # The constructor for the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the arguments *regular_args* as an `Array of Class` and *keyword_args* as an `Array of TypeDeclaration`.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  #
  # The arguments *block_arg_number* and *block_return_type* can be set to an `Int` and a `Class`,
  # respectively, in order to require a block argument. If *store_block_arg* is set to `true`,
  # any block argument given will be stored in a cache.
  macro wrap_constructor_with_keywords(rb_interpreter, crystal_class, keyword_args, regular_args = nil, operator = "", context = nil, block_arg_number = nil, block_return_type = nil, store_block_arg = false)
    {%
      options = {
        :context           => context,
        :block_arg_number  => block_arg_number,
        :block_return_type => block_return_type,
        :store_block_arg   => store_block_arg,
      }
    %}
    Anyolite::Macro.wrap_constructor_function_with_keyword_args({{rb_interpreter}}, {{crystal_class}}, {{crystal_class}}.new, {{keyword_args}}, {{regular_args}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps a module function into mruby.
  #
  # The function *proc* under the module *under_module* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the arguments *proc_args* as an `Array of Class`.
  #
  # Its new name will be *name*.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  # The value *return_nil* will override any returned value with `nil`.
  #
  # The arguments *block_arg_number* and *block_return_type* can be set to an `Int` and a `Class`,
  # respectively, in order to require a block argument. If *store_block_arg* is set to `true`,
  # any block argument given will be stored in a cache.
  macro wrap_module_function(rb_interpreter, under_module, name, proc, proc_args = nil, operator = "", context = nil, return_nil = false, block_arg_number = nil, block_return_type = nil, store_block_arg = false)
    {%
      options = {
        :context           => context,
        :return_nil        => return_nil,
        :block_arg_number  => block_arg_number,
        :block_return_type => block_return_type,
        :store_block_arg   => store_block_arg,
      }
    %}
    Anyolite::Macro.wrap_module_function_with_args({{rb_interpreter}}, {{under_module}}, {{name}}, {{proc}}, {{proc_args}}, options: {{options}})
  end

  # Wraps a module function into mruby, using keyword arguments.
  #
  # The function *proc* under the module *under_module* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the arguments *regular_args* as an `Array of Class` and *keyword_args* as an `Array of TypeDeclaration`.
  #
  # Its new name will be *name*.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  # The value *return_nil* will override any returned value with `nil`.
  #
  # The arguments *block_arg_number* and *block_return_type* can be set to an `Int` and a `Class`,
  # respectively, in order to require a block argument. If *store_block_arg* is set to `true`,
  # any block argument given will be stored in a cache.
  macro wrap_module_function_with_keywords(rb_interpreter, under_module, name, proc, keyword_args, regular_args = nil, operator = "", context = nil, return_nil = false, block_arg_number = nil, block_return_type = nil, store_block_arg = false)
    {%
      options = {
        :context           => context,
        :return_nil        => return_nil,
        :block_arg_number  => block_arg_number,
        :block_return_type => block_return_type,
        :store_block_arg   => store_block_arg,
      }
    %}
    Anyolite::Macro.wrap_module_function_with_keyword_args({{rb_interpreter}}, {{under_module}}, {{name}}, {{proc}}, {{keyword_args}}, {{regular_args}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps a class method into mruby.
  #
  # The class method *proc* of the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the arguments *proc_args* as an `Array of Class`.
  #
  # Its new name will be *name*.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  # The value *return_nil* will override any returned value with `nil`.
  #
  # The arguments *block_arg_number* and *block_return_type* can be set to an `Int` and a `Class`,
  # respectively, in order to require a block argument. If *store_block_arg* is set to `true`,
  # any block argument given will be stored in a cache.
  macro wrap_class_method(rb_interpreter, crystal_class, name, proc, proc_args = nil, operator = "", context = nil, return_nil = false, block_arg_number = nil, block_return_type = nil, store_block_arg = false)
    {%
      options = {
        :context           => context,
        :return_nil        => return_nil,
        :block_arg_number  => block_arg_number,
        :block_return_type => block_return_type,
        :store_block_arg   => store_block_arg,
      }
    %}
    Anyolite::Macro.wrap_class_method_with_args({{rb_interpreter}}, {{crystal_class}}, {{name}}, {{proc}}, {{proc_args}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps a class method into mruby, using keyword arguments.
  #
  # The class method *proc* of the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the arguments *regular_args* as an `Array of Class` and *keyword_args* as an `Array of TypeDeclaration`.
  #
  # Its new name will be *name*.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  # The value *return_nil* will override any returned value with `nil`.
  #
  # The arguments *block_arg_number* and *block_return_type* can be set to an `Int` and a `Class`,
  # respectively, in order to require a block argument. If *store_block_arg* is set to `true`,
  # any block argument given will be stored in a cache.
  macro wrap_class_method_with_keywords(rb_interpreter, crystal_class, name, proc, keyword_args, regular_args = nil, operator = "", context = nil, return_nil = false, block_arg_number = nil, block_return_type = nil, store_block_arg = false)
    {%
      options = {
        :context           => context,
        :return_nil        => return_nil,
        :block_arg_number  => block_arg_number,
        :block_return_type => block_return_type,
        :store_block_arg   => store_block_arg,
      }
    %}
    Anyolite::Macro.wrap_class_method_with_keyword_args({{rb_interpreter}}, {{crystal_class}}, {{name}}, {{proc}}, {{keyword_args}}, {{regular_args}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps an instance method into mruby.
  #
  # The instance method *proc* of the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the arguments *proc_args* as an `Array of Class`.
  #
  # Its new name will be *name*.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  # The value *return_nil* will override any returned value with `nil`.
  #
  # The arguments *block_arg_number* and *block_return_type* can be set to an `Int` and a `Class`,
  # respectively, in order to require a block argument. If *store_block_arg* is set to `true`,
  # any block argument given will be stored in a cache.
  macro wrap_instance_method(rb_interpreter, crystal_class, name, proc, proc_args = nil, operator = "", context = nil, return_nil = false, block_arg_number = nil, block_return_type = nil, store_block_arg = false)
    {%
      options = {
        :context           => context,
        :return_nil        => return_nil,
        :block_arg_number  => block_arg_number,
        :block_return_type => block_return_type,
        :store_block_arg   => store_block_arg,
      }
    %}
    Anyolite::Macro.wrap_instance_function_with_args({{rb_interpreter}}, {{crystal_class}}, {{name}}, {{proc}}, {{proc_args}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps an instance method into mruby, using keyword arguments.
  #
  # The instance method *proc* of the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the arguments *regular_args* as an `Array of Class` and *keyword_args* as an `Array of TypeDeclaration`.
  #
  # Its new name will be *name*.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  # The value *return_nil* will override any returned value with `nil`.
  #
  # The arguments *block_arg_number* and *block_return_type* can be set to an `Int` and a `Class`,
  # respectively, in order to require a block argument. If *store_block_arg* is set to `true`,
  # any block argument given will be stored in a cache.
  macro wrap_instance_method_with_keywords(rb_interpreter, crystal_class, name, proc, keyword_args, regular_args = nil, operator = "", context = nil, return_nil = false, block_arg_number = nil, block_return_type = nil, store_block_arg = false)
    {%
      options = {
        :context           => context,
        :return_nil        => return_nil,
        :block_arg_number  => block_arg_number,
        :block_return_type => block_return_type,
        :store_block_arg   => store_block_arg,
      }
    %}
    Anyolite::Macro.wrap_instance_function_with_keyword_args({{rb_interpreter}}, {{crystal_class}}, {{name}}, {{proc}}, {{keyword_args}}, {{regular_args}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps a setter into mruby.
  #
  # The setter *proc* (without the `=`) of the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the argument *proc_arg* as its respective `Class`.
  #
  # Its new name will be *name*.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  macro wrap_setter(rb_interpreter, crystal_class, name, proc, proc_arg, operator = "=", context = nil)
    {% options = {:context => context} %}
    Anyolite::Macro.wrap_instance_function_with_args({{rb_interpreter}}, {{crystal_class}}, {{name}}, {{proc}}, {{proc_arg}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps a getter into mruby.
  #
  # The getter *proc* of the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*.
  #
  # Its new name will be *name*.
  #
  # The value *operator* will append the specified `String`
  # to the final name and *context* can give the function a `Path` for resolving types correctly.
  macro wrap_getter(rb_interpreter, crystal_class, name, proc, operator = "", context = nil)
    {% options = {:context => context} %}
    Anyolite::Macro.wrap_instance_function_with_args({{rb_interpreter}}, {{crystal_class}}, {{name}}, {{proc}}, operator: {{operator}}, options: {{options}})
  end

  # Wraps a property into mruby.
  #
  # The property *proc* of the Crystal `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the argument *proc_arg* as its respective `Class`.
  #
  # Its new name will be *name*.
  #
  # The values *operator_getter* and *operator_setter* will append the specified `String`
  # to the final names and *context* can give the function a `Path` for resolving types correctly.
  macro wrap_property(rb_interpreter, crystal_class, name, proc, proc_arg, operator_getter = "", operator_setter = "=", context = nil)
    Anyolite.wrap_getter({{rb_interpreter}}, {{crystal_class}}, {{name}}, {{proc}}, operator: {{operator_getter}}, context: {{context}})
    Anyolite.wrap_setter({{rb_interpreter}}, {{crystal_class}}, {{name + "="}}, {{proc}}, {{proc_arg}}, operator: {{operator_setter}}, context: {{context}})
  end

  # Wraps a constant value under a module into mruby.
  #
  # The value *crystal_value* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the name *name* and the parent module *under_module*.
  macro wrap_constant(rb_interpreter, under_module, name, crystal_value)
    Anyolite::RbCore.rb_define_const({{rb_interpreter}}, Anyolite::RbClassCache.get({{under_module}}), {{name}}, Anyolite::RbCast.return_value({{rb_interpreter}}.to_unsafe, {{crystal_value}}))
  end

  # Wraps a constant value under a class into mruby.
  #
  # The value *crystal_value* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the name *name* and the parent `Class` *under_class*.
  macro wrap_constant_under_class(rb_interpreter, under_class, name, crystal_value)
    Anyolite::RbCore.rb_define_const({{rb_interpreter}}, Anyolite::RbClassCache.get({{under_class}}), {{name}}, Anyolite::RbCast.return_value({{rb_interpreter}}.to_unsafe, {{crystal_value}}))
  end

  # NOTE: Annotations like SpecializeConstant are not defined for obvious reasons
  # TODO: Annotations for constants are currently not obtainable with macros (?)

  # Excludes the function from wrapping.
  annotation Exclude; end

  # Excludes the instance method given as the first argument from wrapping.
  # Use it on `Object` to exclude the named method from all classes.
  annotation ExcludeInstanceMethod; end

  # Excludes the class method given as the first argument from wrapping.
  annotation ExcludeClassMethod; end

  # Excludes the constant given as the first argument from wrapping.
  annotation ExcludeConstant; end

  # Overrides `ExcludeInstanceMethod` on `Object`.
  annotation Include; end

  # Overrides `ExcludeInstanceMethod` on `Object`
  # the instance method given as the first argument.
  annotation IncludeInstanceMethod; end

  # Excludes all definitions of this function besides this one from wrapping.
  # The optional first argument overwrites the original argument array.
  annotation Specialize; end

  # Excludes all definitions of the instance method given as the first argument
  # besides the one with the arguments given in the second argument (`nil` for none) from wrapping.
  # The optional third argument overwrites the original argument array.
  annotation SpecializeInstanceMethod; end

  # Excludes all definitions of the class method given as the first argument
  # besides the one with the arguments given in the second argument (`nil` for none) from wrapping.
  # The optional third argument overwrites the original argument array.
  annotation SpecializeClassMethod; end

  # Renames the function to the first argument if wrapped.
  annotation Rename; end

  # Renames the instane method given as the first argument
  # to the second argument if wrapped.
  annotation RenameInstanceMethod; end

  # Renames the class method given as the first argument
  # to the second argument if wrapped.
  annotation RenameClassMethod; end

  # Renames the constant given as the first argument
  # to the second argument if wrapped.
  annotation RenameConstant; end

  # Renames the class to the first argument if wrapped.
  annotation RenameClass; end

  # Renames the module to the first argument if wrapped.
  annotation RenameModule; end

  # Wraps all arguments of the function to positional arguments.
  # The optional argument limits the number of arguments to wrap as positional
  # arguments (`-1` for all arguments).
  annotation WrapWithoutKeywords; end

  # Wraps all arguments of the instance method given as the first argument
  # to positional arguments.
  # The optional seconds argument limits the number of arguments to wrap as positional
  # arguments (`-1` for all arguments).
  annotation WrapWithoutKeywordsInstanceMethod; end

  # Wraps all arguments of the class method given as the first argument
  # to positional arguments.
  # The optional seconds argument limits the number of arguments to wrap as positional
  # arguments (`-1` for all arguments).
  annotation WrapWithoutKeywordsClassMethod; end

  # Lets the function always return `nil`.
  annotation ReturnNil; end

  # Lets the instance method given as the first argument always return `nil`.
  annotation ReturnNilInstanceMethod; end

  # Lets the class method given as the first argument always return `nil`.
  annotation ReturnNilClassMethod; end

  # Specifies the generic type names for the following class as its argument,
  # in form of an `Array` of their names.
  annotation SpecifyGenericTypes; end

  # Specifies the method to require a block argument with the first argument
  # being the number of values yielded and the second argument the return
  # type of the block.
  annotation AddBlockArg; end

  # Specifies the instance method given as the first argument
  # to require a block argument with the second argument
  # being the number of values yielded and the third argument the return
  # type of the block.
  annotation AddBlockArgInstanceMethod; end

  # Specifies the class method given as the first argument
  # to require a block argument with the second argument
  # being the number of values yielded and the third argument the return
  # type of the block.
  annotation AddBlockArgClassMethod; end

  # Instructs the function to cache an incoming Ruby block argument if given.
  annotation StoreBlockArg; end

  # Instructs the instance method given as the first argument to cache an incoming Ruby block argument if given.
  annotation StoreBlockArgInstanceMethod; end

  # Instructs the class method given as the first argument to cache an incoming Ruby block argument if given.
  annotation StoreBlockArgClassMethod; end

  # Forces the method to use keyword arguments (especially for operator methods) if given.
  annotation ForceKeywordArg; end

  # Forces the instance method given as the first argument to use
  # keyword arguments (especially for operator methods) if given.
  annotation ForceKeywordArgInstanceMethod; end

  # Forces the class method given as the first argument to use
  # keyword arguments (especially for operator methods) if given.
  annotation ForceKeywordArgClassMethod; end

  # The methods of the annotated class or module will not
  # be wrapped with keyword arguments unless `ForceKeywordArg`
  # or similar was used.
  annotation NoKeywordArgs; end

  # All methods of the respective class have their required arguments
  # wrapped as regular arguments and their optional arguments wrapped
  # as keyword arguments.
  #
  # The annotation can be overwritten with the respective
  # `WrapWithoutKeywords` annotations for specific methods.
  annotation DefaultOptionalArgsToKeywordArgs; end

  # Specifies that only the directly defined methods of the respective
  # class are wrapped, and no inherited methods.
  annotation IgnoreAncestorMethods; end

  # Wraps a whole class structure under a module into mruby.
  #
  # The `Class` *crystal_class* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the optional parent module *under*.
  # Methods or constants to be excluded can be specified as
  # `Symbol` or `String` in the `Array`
  # *instance_method_exclusions* (for instance methods),
  # *class_method_exclusions* (for class methods) or
  # *constant_exclusions* (for constants).
  #
  # Enum classes can be wrapped by setting *use_enum_methods*.
  # If *wrap_equality_method* is set, the `==` method will be wrapped
  # automatically.
  # Setting *connect_to_superclass* to `false` will force the algorithm
  # to ignore any superclass.
  # Setting *include_ancestor_methods* will include any methods
  # from nontrivial ancestor classes.
  # The option *overwrite* will iterate through all functions and
  # constants again if set to `true`.
  # If *verbose* is set, wrapping information will be displayed.
  macro wrap_class_with_methods(rb_interpreter, crystal_class, under = nil,
                                instance_method_exclusions = [] of String | Symbol,
                                class_method_exclusions = [] of String | Symbol,
                                constant_exclusions = [] of String | Symbol,
                                use_enum_methods = false,
                                wrap_equality_method = false,
                                connect_to_superclass = true,
                                include_ancestor_methods = true,
                                overwrite = false,
                                verbose = false)

    {% if verbose %}
      {% puts ">>> Going into class #{crystal_class} under #{under}\n\n" %}
    {% end %}

    {% if crystal_class.is_a?(Generic) %}
      {% puts "> Wrapping of generics not supported, thus skipping #{crystal_class}\e[0m\n\n" if verbose %}
    {% else %}
      {% resolved_class = crystal_class.resolve %}

      {% new_context = crystal_class %}

      {% if resolved_class.annotation(Anyolite::RenameClass) %}
        {% actual_name = resolved_class.annotation(Anyolite::RenameClass)[0] %}
      {% else %}
        {% actual_name = crystal_class.names.last.stringify %}
      {% end %}

      {% if connect_to_superclass %}
        {% superclass = [Reference, Object, Struct, Enum, Value, Comparable(Enum), Enumerable].includes?(resolved_class.superclass) ? nil : resolved_class.superclass %}
      {% else %}
        {% superclass = nil %}
      {% end %}

      {% if superclass %}
        if !Anyolite::RbClassCache.check({{superclass.resolve}})
          puts "Note: Superclass {{superclass}} to {{resolved_class}} was not wrapped before. Trying to find it..."
          _needs_more_iterations.push("{{superclass}}") if _needs_more_iterations
        else
      {% else %}
        if false

        else
      {% end %}
        if {{overwrite}} || !Anyolite::RbClassCache.check({{resolved_class}}) 
          Anyolite.wrap_class({{rb_interpreter}}, {{resolved_class}}, {{actual_name}}, under: {{under}}, superclass: {{superclass}})

          {% if include_ancestor_methods %}
            {% reversed_ancestors = [] of TypeNode %}
            {% for ancestor in resolved_class.ancestors.reject { |ancestor| [Object, Reference, Struct, Enum, Value, Comparable(Enum), Enumerable].includes?(ancestor) } %}
              {% reversed_ancestors = [ancestor] + reversed_ancestors %}
            {% end %}

            {% puts "> Ancestors for #{resolved_class}: #{reversed_ancestors}" if !reversed_ancestors.empty? && verbose %}

            {% if resolved_class.annotation(Anyolite::IgnoreAncestorMethods) %}
              {% puts "> Ignoring ancestors due to annotation." if !reversed_ancestors.empty? && verbose %}
            {% else %}
              {% for ancestor, ancestor_index in reversed_ancestors %}
                {% puts "> Going into ancestor #{ancestor} for #{resolved_class}..." if verbose %}
                {% later_ancestors = reversed_ancestors[ancestor_index + 1..-1] %}

                Anyolite::Macro.wrap_all_instance_methods({{rb_interpreter}}, {{crystal_class}}, {{instance_method_exclusions}}, 
                  verbose: {{verbose}}, context: {{new_context}}, use_enum_methods: {{use_enum_methods}}, wrap_equality_method: {{wrap_equality_method}}, 
                  other_source: {{ancestor}}, later_ancestors: {{later_ancestors.empty? ? nil : later_ancestors}})
              {% end %}
            {% end %}
          {% end %}

          Anyolite::Macro.wrap_all_instance_methods({{rb_interpreter}}, {{crystal_class}}, {{instance_method_exclusions}}, 
            verbose: {{verbose}}, context: {{new_context}}, use_enum_methods: {{use_enum_methods}}, wrap_equality_method: {{wrap_equality_method}})
          Anyolite::Macro.wrap_all_class_methods({{rb_interpreter}}, {{crystal_class}}, {{class_method_exclusions}}, verbose: {{verbose}}, context: {{new_context}})
          Anyolite::Macro.wrap_all_constants({{rb_interpreter}}, {{crystal_class}}, {{constant_exclusions}}, verbose: {{verbose}}, context: {{new_context}})
        end
      end
    {% end %}
  end

  # Wraps a whole module structure under a module into mruby.
  #
  # The module *crystal_module* will be integrated into the `RbInterpreter` *rb_interpreter*,
  # with the optional parent module *under*.
  # Methods or constants to be excluded can be specified as
  # `Symbol` or `String` in the `Array`
  # *class_method_exclusions* (for class methods) or
  # *constant_exclusions* (for constants).
  # The option *overwrite* will iterate through all functions and
  # constants again if set to `true`.
  # If *verbose* is set, wrapping information will be displayed.
  macro wrap_module_with_methods(rb_interpreter, crystal_module, under = nil,
                                 class_method_exclusions = [] of String | Symbol,
                                 constant_exclusions = [] of String | Symbol,
                                 overwrite = false,
                                 verbose = false)

    {% if verbose %}
      {% puts ">>> Going into module #{crystal_module} under #{under}\n\n" %}
    {% end %}

    {% new_context = crystal_module %}

    {% if crystal_module.resolve.annotation(Anyolite::RenameModule) %}
      {% actual_name = crystal_module.resolve.annotation(Anyolite::RenameModule)[0] %}
    {% else %}
      {% actual_name = crystal_module.names.last.stringify %}
    {% end %}

    if {{overwrite}} || !Anyolite::RbClassCache.check({{crystal_module.resolve}}) 
      Anyolite.wrap_module({{rb_interpreter}}, {{crystal_module.resolve}}, {{actual_name}}, under: {{under}})

      Anyolite::Macro.wrap_all_class_methods({{rb_interpreter}}, {{crystal_module}}, {{class_method_exclusions}}, verbose: {{verbose}}, context: {{new_context}})
      Anyolite::Macro.wrap_all_constants({{rb_interpreter}}, {{crystal_module}}, {{constant_exclusions}}, verbose: {{verbose}}, overwrite: {{overwrite}}, context: {{new_context}})
    end
  end

  # Wraps a whole class or module structure under a module into mruby.
  #
  # The class or module *crystal_module_or_class* will be integrated
  # into the `RbInterpreter` *rb_interpreter*,
  # with the optional parent module *under*.
  # Methods or constants to be excluded can be specified as
  # `Symbol` or `String` in the `Array`
  # *class_method_exclusions* (for class methods) or
  # *constant_exclusions* (for constants).
  #
  # If *wrap_equality_method* is set, the `==` method will be wrapped
  # automatically.
  # Setting *connect_to_superclass* to `false` will force the algorithm
  # to ignore any superclass.
  # Setting *include_ancestor_methods* will include any methods
  # from nontrivial ancestor classes.
  # The option *overwrite* will iterate through all functions and
  # constants again if set to `true`.
  # If *verbose* is set, wrapping information will be displayed.
  macro wrap(rb_interpreter, crystal_module_or_class, under = nil,
             instance_method_exclusions = [] of String | Symbol,
             class_method_exclusions = [] of String | Symbol,
             constant_exclusions = [] of String | Symbol,
             connect_to_superclass = false,
             include_ancestor_methods = true,
             use_enum_methods = false,
             wrap_equality_method = false,
             overwrite = false,
             verbose = false)

    _needs_more_iterations = [] of String
    %previous_iterations = [] of String
    %first_run = true

    while %first_run || !_needs_more_iterations.empty?
      %previous_iterations = _needs_more_iterations
      _needs_more_iterations = [] of String

      {% if !crystal_module_or_class.is_a?(Path) %}
        {% puts "\e[31m> WARNING: Object #{crystal_module_or_class} of #{crystal_module_or_class.class_name.id} is neither a class nor module, so it will be skipped\e[0m" %}
      {% elsif crystal_module_or_class.resolve.module? %}
        Anyolite.wrap_module_with_methods({{rb_interpreter}}, {{crystal_module_or_class}}, under: {{under}},
          class_method_exclusions: {{class_method_exclusions}},
          constant_exclusions: {{constant_exclusions}},
          overwrite: {{overwrite}},
          verbose: {{verbose}}
        )
      {% elsif crystal_module_or_class.resolve.class? || crystal_module_or_class.resolve.struct? %}
        Anyolite.wrap_class_with_methods({{rb_interpreter}}, {{crystal_module_or_class}}, under: {{under}},
          instance_method_exclusions: {{instance_method_exclusions}},
          class_method_exclusions: {{class_method_exclusions}},
          constant_exclusions: {{constant_exclusions}},
          use_enum_methods: {{use_enum_methods}},
          wrap_equality_method: {{wrap_equality_method || crystal_module_or_class.resolve.struct?}},
          connect_to_superclass: {{connect_to_superclass}},
          include_ancestor_methods: {{include_ancestor_methods}},
          overwrite: {{overwrite}},
          verbose: {{verbose}}
        )
      {% elsif crystal_module_or_class.resolve.union? %}
        {% puts "\e[31m> WARNING: Wrapping of unions not supported, thus skipping #{crystal_module_or_class}\e[0m" %}
      {% elsif crystal_module_or_class.resolve < Enum %}
        Anyolite.wrap_class_with_methods({{rb_interpreter}}, {{crystal_module_or_class}}, under: {{under}},
          instance_method_exclusions: {{instance_method_exclusions}},
          class_method_exclusions: {{class_method_exclusions}},
          constant_exclusions: {{constant_exclusions}},
          use_enum_methods: true,
          wrap_equality_method: true,
          connect_to_superclass: {{connect_to_superclass}},
          include_ancestor_methods: {{include_ancestor_methods}},
          overwrite: {{overwrite}},
          verbose: {{verbose}}
        )
      {% elsif crystal_module_or_class.resolve.is_a?(TypeNode) %}
        Anyolite.wrap_class_with_methods({{rb_interpreter}}, {{crystal_module_or_class}}, under: {{under}},
          instance_method_exclusions: {{instance_method_exclusions}},
          class_method_exclusions: {{class_method_exclusions}},
          constant_exclusions: {{constant_exclusions}},
          use_enum_methods: {{use_enum_methods}},
          wrap_equality_method: {{wrap_equality_method}},
          connect_to_superclass: {{connect_to_superclass}},
          include_ancestor_methods: {{include_ancestor_methods}},
          overwrite: {{overwrite}},
          verbose: {{verbose}}
        )
      {% else %}
        {% puts "\e[31m> WARNING: Could not resolve #{crystal_module_or_class}, so it will be skipped\e[0m" %}
      {% end %}

      %first_run = false

      if !_needs_more_iterations.empty? && _needs_more_iterations == %previous_iterations
        raise "Could not wrap the following classes: #{_needs_more_iterations.inspect}"
      end
    end
  end
end

require "./helper_classes/HelperClasses.cr"
