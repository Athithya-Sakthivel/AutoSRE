package com.rivulet.gateway.producer;

/**
 * Phase 3 producer contract.
 *
 * <p>The concrete Valkey implementation is supplied in Phase 5.
 */
public interface ValkeyStreamProducer {

    /**
     * Publishes an already-serialized order event to a Valkey stream.
     *
     * @param streamName target Valkey stream
     * @param payloadJson serialized event payload
     * @return producer metadata for the published message
     */
    MessageEnvelope produce(String streamName, String payloadJson);
}
