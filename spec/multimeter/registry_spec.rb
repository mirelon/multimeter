require_relative '../spec_helper'


module Multimeter
  module RegistrySpecs
    class ClassWithInstanceMetrics
      include InstanceMetrics

      instance_id { @id }
      counter :count

      def initialize(id)
        @id = id
        super()
      end

      def c!
        counter.inc
      end
    end

    class ClassWithLinkedInstanceMetrics
      include LinkedInstanceMetrics

      instance_id { "instance-#{@id}" }
      scope :example
      counter :count
      gauge :current do
        value
      end

      def initialize(id)
        @id = id
        super()
      end

      def c!
        count.inc
      end

      def value
        count.count
      end
    end
  end

  describe Registry do
    let :registry do
      Multimeter.registry('a_group', 'some_scope')
    end

    context 'when creating metrics' do
      [:counter, :meter, :histogram, :timer].each do |metric_type|
        it "##{metric_type} creates a new #{metric_type}" do
          metric = registry.send(metric_type, :some_name)
          metric.should_not be_nil
        end
      end

      it '#gauge creates a gauge' do
        registry.gauge(:some_name) { 42 }
      end

      it 'caches metric objects' do
        registry.counter(:some_name).should equal(registry.counter(:some_name))
      end

      it 'raises an error when a gauge is redeclared, but not when it is accessed without a block' do
        g1 = registry.gauge(:some_name) { 42 }
        g2 = registry.gauge(:some_name)
        g1.should equal(g2)
        expect { registry.gauge(:some_name) { 43 } }.to raise_error(ArgumentError)
      end

      it 'raises an error if a metric is redeclared as another type' do
        registry.counter(:some_name)
        expect { registry.meter(:some_name) }.to raise_error(ArgumentError)
      end
    end

    context 'with custom registry instance IDs' do
      it 'uses the value returned by the instance_id pragma' do
        i1 = RegistrySpecs::ClassWithInstanceMetrics.new(3)
        i1.multimeter_registry.instance_id.should == 3
      end

      it 'shares registries when two linked instances have the same ID' do
        first = RegistrySpecs::ClassWithLinkedInstanceMetrics.new(3)
        second = RegistrySpecs::ClassWithLinkedInstanceMetrics.new(3)
        first.c!
        second.current.value.should == 1
      end
    end

    describe '#find_metric' do
      let(:sub_registry) { registry.sub_registry('another_scope') }

      before do
        registry.meter(:some_meter)
        sub_registry.meter(:some_meter)
        sub_registry.meter(:another_meter)
      end

      it 'looks in the receiving registry first' do
        m1 = registry.find_metric(:some_meter)
        m2 = registry.get(:some_meter)
        m1.should_not be_nil
        m1.should equal(m2)
      end

      it 'looks in sub registries second' do
        m1 = registry.find_metric(:another_meter)
        m1.should_not be_nil
      end

      it 'looks all the way down into sub sub sub registries and so on' do
        registry.sub_registry('down').sub_registry('down_again').meter(:very_deep)
        m1 = registry.find_metric(:very_deep)
        m1.should_not be_nil
      end

      it 'returns nil if no metric was found in any sub registry' do
        registry.find_metric(:hobbeldygook).should be_nil
      end
    end

    describe '#to_h' do
      it 'returns a hash representation of the registry, including all metrics' do
        c = registry.counter(:some_counter)
        g = registry.gauge(:some_gauge) { 42 }
        c.inc
        registry.to_h.should == {
          'some_scope' => {
            :some_counter => c.to_h,
            :some_gauge => g.to_h
          }
        }
      end

      it 'merges in sub registries, and sub sub registries' do
        sub_registry1 = registry.sub_registry('some_other_scope')
        sub_registry2 = registry.sub_registry('another_scope')
        sub_sub_registry1 = sub_registry2.sub_registry('sub_sub_scope')
        registry.counter(:some_counter).inc
        registry.gauge(:some_gauge) { 42 }
        sub_registry1.counter(:stuff).inc(3)
        sub_registry2.counter(:stuff).inc(2)
        sub_sub_registry1.counter(:things).inc
        registry.to_h.should == {
          'some_scope' => {
            :some_gauge => {:type => :gauge, :value => 42},
            :some_counter => {:type => :counter, :count => 1}
          },
          'some_other_scope' => {
            :stuff => {:type => :counter, :count => 3}
          },
          'another_scope' => {
            :stuff => {:type => :counter, :count => 2}
          },
          'sub_sub_scope' => {
            :things => {:type => :counter, :count => 1}
          }
        }
      end

      it 'merges instance registries by creating a meta-metric' do
        instance_registry1 = registry.sub_registry('the_scope', 1)
        instance_registry2 = registry.sub_registry('the_scope', 2)
        instance_registry3 = registry.sub_registry('the_scope', 3)
        instance_registry1.counter(:stuff).inc(2)
        instance_registry1.gauge(:status) { 0 }
        instance_registry2.counter(:stuff).inc(1)
        instance_registry3.counter(:stuff).inc(3)
        registry.to_h.should == {
          'the_scope' => {
            :stuff => {
              :type => :aggregate,
              :total => {:type => :counter, :count => {
                  :min => 1,
                  :max => 3,
                  :sum => 1 + 2 + 3,
                  :avg => 6/3.0
                }
              },
              :parts => {
                '1' => {:type => :counter, :count => 2},
                '2' => {:type => :counter, :count => 1},
                '3' => {:type => :counter, :count => 3}
              }
            },
            :status => {:type => :gauge, :value => 0}
          }
        }
      end

      it 'prunes empty scopes' do
        sub_registry1 = registry.sub_registry('scope1')
        sub_registry1.counter(:count1).inc
        registry.to_h.should == {
          'scope1' => {:count1 => {:type => :counter, :count => 1}}
        }
      end
    end
  end
end