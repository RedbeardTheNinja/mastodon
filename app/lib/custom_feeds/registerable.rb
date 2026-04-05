# frozen_string_literal: true

module CustomFeeds
  # Shared registry pattern for pluggable step types.
  # Include in base classes that need a REGISTRY / key / register! triple.
  #
  # Usage:
  #   class Base
  #     include CustomFeeds::Registerable
  #   end
  #
  #   class MyImpl < Base
  #     def self.key = 'my_impl'
  #   end
  #   MyImpl.register!            # => registers in Base.registry
  #   Base.registry['my_impl']    # => MyImpl
  module Registerable
    def self.included(base)
      base.instance_variable_set(:@registry, {})
      base.extend(ClassMethods)
    end

    module ClassMethods
      def registry
        return @registry if instance_variable_defined?(:@registry)

        superclass.registry
      end

      def key
        raise NotImplementedError, "#{name} must implement .key"
      end

      def register!
        registry[key] = self
      end
    end
  end
end
