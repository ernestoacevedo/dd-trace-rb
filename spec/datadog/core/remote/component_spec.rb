# frozen_string_literal: true

require 'spec_helper'
require 'datadog/core/remote/component'

RSpec.describe Datadog::Core::Remote::Component do
  let(:settings) { Datadog::Core::Configuration::Settings.new }
  let(:agent_settings) { Datadog::Core::Configuration::AgentSettingsResolver.call(settings, logger: nil) }
  let(:capabilities) { Datadog::Core::Remote::Client::Capabilities.new(settings) }

  describe '.build' do
    subject(:component) { described_class.build(settings, agent_settings) }

    context 'remote disabled' do
      let(:remote) do
        mock = double('remote')
        expect(mock).to receive(:enabled).and_return(false)
        mock
      end

      before { expect(settings).to receive(:remote).and_return(remote) }

      it 'returns nil ' do
        expect(component).to be_nil
      end
    end

    context 'remote enabled' do
      context 'appsec' do
        before { expect(settings).to receive(:appsec).and_return(appsec) }

        let(:appsec) do
          mock = double('appsec')
          expect(mock).to receive(:enabled).and_return(appsec_enabled)
          mock
        end

        context 'disabled' do
          let(:appsec_enabled) { false }

          it 'returns nil ' do
            expect(component).to be_nil
          end
        end

        context 'enabled' do
          let(:appsec_enabled) { true }

          context 'agent comunication' do
            before do
              request_class = ::Net::HTTP::Get
              http_request = instance_double(request_class)
              allow(http_request).to receive(:body=)
              allow(request_class).to receive(:new).and_return(http_request)

              http_connection = instance_double(::Net::HTTP)
              allow(::Net::HTTP).to receive(:new).and_return(http_connection)

              allow(http_connection).to receive(:open_timeout=)
              allow(http_connection).to receive(:read_timeout=)
              allow(http_connection).to receive(:use_ssl=)

              allow(http_connection).to receive(:start).and_yield(http_connection)
              http_response = instance_double(::Net::HTTPResponse, body: response_body, code: response_code)
              allow(http_connection).to receive(:request).with(http_request).and_return(http_response)
            end

            context 'agent unreacheable' do
              let(:response_code) { 500 }
              let(:response_body) { {}.to_json }

              it 'returns nil ' do
                expect(component).to be_nil
              end
            end

            context 'agent reachable but no support for remote configuration' do
              let(:response_code) { 500 }
              let(:response_body) do
                {
                  'endpoints' => ['no_config']
                }.to_json
              end

              it 'returns nil ' do
                expect(component).to be_nil
              end
            end

            context 'agent reachable with support for remote configuration' do
              let(:response_code) { 200 }
              let(:response_body) do
                {
                  'endpoints' => ['/v0.7/config']
                }.to_json
              end

              it 'returns component' do
                expect(component).to be_a(described_class)
              end
            end
          end
        end
      end
    end
  end

  describe '#initialize' do
    subject(:component) { described_class.new(settings, capabilities, agent_settings) }

    after do
      component.shutdown!
    end

    context 'worker' do
      let(:worker) { component.instance_eval { @worker } }
      let(:client) { double }
      let(:transport_v7) { double }

      before do
        expect(Datadog::Core::Transport::HTTP).to receive(:v7).and_return(transport_v7)
        expect(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

        expect(worker).to receive(:start).and_call_original
        expect(worker).to receive(:stop).and_call_original
      end

      context 'when client sync succeeds' do
        before do
          expect(worker).to receive(:call).and_call_original
          expect(client).to receive(:sync).and_return(nil)
        end

        it 'does not log any error' do
          expect(Datadog.logger).to_not receive(:error)

          component.barrier(:once)
        end
      end

      context 'when client sync raises' do
        before do
          expect(worker).to receive(:call).and_call_original
          expect(client).to receive(:sync).and_raise(exception, 'test')
          allow(Datadog.logger).to receive(:error).and_return(nil)
        end

        context 'StandardError' do
          let(:second_client) { double }
          let(:exception) { Class.new(StandardError) }

          it 'logs an error' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

            expect(Datadog.logger).to receive(:error).and_return(nil)

            component.barrier(:once)
          end

          it 'catches exceptions' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

            # if the error is uncaught it will crash the test, so a mere passing is good

            component.barrier(:once)
          end

          it 'creates a new client' do
            expect(Datadog::Core::Remote::Client).to receive(:new).and_return(second_client)

            expect(component.client.object_id).to eql(client.object_id)

            component.barrier(:once)

            expect(component.client.object_id).to eql(second_client.object_id)
          end
        end

        context 'Client::SyncError' do
          let(:exception) { Class.new(Datadog::Core::Remote::Client::SyncError) }

          it 'logs an error' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

            expect(Datadog.logger).to receive(:error).and_return(nil)

            component.barrier(:once)
          end

          it 'catches exceptions' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

            # if the error is uncaught it will crash the test, so a mere passing is good

            component.barrier(:once)
          end

          it 'does not creates a new client' do
            expect(Datadog::Core::Remote::Client).to_not receive(:new)

            expect(component.client.object_id).to eql(client.object_id)

            component.barrier(:once)

            expect(component.client.object_id).to eql(client.object_id)
          end
        end
      end
    end
  end
end

RSpec.describe Datadog::Core::Remote::Component::Barrier do
  let(:delay) { 0.5 }
  let(:timeout) { nil }
  let(:instance_timeout) { nil }

  subject(:barrier) { described_class.new(instance_timeout) }

  shared_context('recorder') do
    let(:record) { [] }
  end

  shared_context('waiter thread') do
    include_context 'recorder'

    let(:thr) do
      Thread.new do
        loop do
          record << :wait
          barrier.wait_next
        end
      end
    end

    before do
      thr.run
    end

    after do
      thr.kill
      thr.join
    end
  end

  shared_context('lifter thread') do
    include_context 'recorder'

    let(:thr) do
      Thread.new do
        loop do
          sleep delay
          record << :lift
          barrier.lift
        end
      end
    end

    before do
      record
      thr.run
    end

    after do
      thr.kill
      thr.join
    end
  end

  describe '#initialize' do
    it 'accepts one argument' do
      expect { described_class.new(instance_timeout) }.to_not raise_error
    end

    it 'accepts zero argument' do
      expect { described_class.new }.to_not raise_error
    end
  end

  describe '#lift' do
    context 'without waiters' do
      include_context 'recorder'

      it 'does not block' do
        record << :one
        barrier.lift
        record << :two

        expect(record).to eq [:one, :two]
      end
    end

    context 'with waiters' do
      include_context 'waiter thread'

      it 'unblocks waiters' do
        sleep delay
        record << :one
        barrier.lift

        sleep delay
        record << :two
        barrier.lift

        # there may be an additional :wait if waiter thread gets switched to
        recorded = record[0, 4]

        expect(recorded).to eq [:wait, :one, :wait, :two]
      end
    end
  end

  describe '#wait_once' do
    include_context 'lifter thread'

    it 'blocks once' do
      record << :one
      barrier.wait_once
      record << :two

      expect(record).to eq [:one, :lift, :two]
    end

    it 'blocks only once' do
      record << :one
      barrier.wait_once
      record << :two
      barrier.wait_once
      record << :three

      expect(record).to eq [:one, :lift, :two, :three]
    end

    context('with a local timeout') do
      let(:timeout) { delay / 4 }

      context('shorter than lift') do
        it 'unblocks on timeout' do
          record << :one
          barrier.wait_once(timeout)
          record << :two
          barrier.wait_once(timeout)
          record << :three

          expect(record).to eq [:one, :two, :three]
        end
      end

      context('longer than lift') do
        let(:delay) { 0.2 }
        let(:timeout) { delay * 2 }

        it 'unblocks before timeout' do
          record << :one
          barrier.wait_once(timeout)
          record << :two
          barrier.wait_once(timeout)
          record << :three

          expect(record).to eq [:one, :lift, :two, :three]
        end
      end

      context('and an instance timeout') do
        let(:instance_timeout) { delay * 2 }

        it 'prefers the local timeout' do
          record << :one
          barrier.wait_once(timeout)
          record << :two
          barrier.wait_once(timeout)
          record << :three

          expect(record).to eq [:one, :two, :three]
        end
      end
    end

    context('with an instance timeout') do
      let(:instance_timeout) { delay / 4 }

      it 'unblocks on timeout' do
        record << :one
        barrier.wait_once
        record << :two
        barrier.wait_once
        record << :three

        expect(record).to eq [:one, :two, :three]
      end
    end
  end

  describe '#wait_next' do
    include_context 'lifter thread'

    it 'blocks once' do
      record << :one
      barrier.wait_next
      record << :two

      expect(record).to eq [:one, :lift, :two]
    end

    it 'blocks each time' do
      record << :one
      barrier.wait_next
      record << :two
      barrier.wait_next
      record << :three

      expect(record).to eq [:one, :lift, :two, :lift, :three]
    end

    context('with a local timeout') do
      let(:timeout) { delay / 4 }

      context('shorter than lift') do
        it 'unblocks on timeout' do
          record << :one
          barrier.wait_next(timeout)
          record << :two
          barrier.wait_next(timeout)
          record << :three

          expect(record).to eq [:one, :two, :three]
        end
      end

      context('longer than lift') do
        let(:delay) { 0.2 }
        let(:timeout) { delay * 2 }

        it 'unblocks before timeout' do
          record << :one
          barrier.wait_next(timeout)
          record << :two
          barrier.wait_next(timeout)
          record << :three

          expect(record).to eq [:one, :lift, :two, :lift, :three]
        end
      end

      context('and an instance timeout') do
        let(:instance_timeout) { delay * 2 }

        it 'prefers the local timeout' do
          record << :one
          barrier.wait_next(timeout)
          record << :two
          barrier.wait_next(timeout)
          record << :three

          expect(record).to eq [:one, :two, :three]
        end
      end
    end

    context('with an instance timeout') do
      let(:instance_timeout) { delay / 4 }

      it 'unblocks on timeout' do
        record << :one
        barrier.wait_next
        record << :two
        barrier.wait_next
        record << :three

        expect(record).to eq [:one, :two, :three]
      end
    end
  end
end
