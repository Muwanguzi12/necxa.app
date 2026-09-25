import { Kafka, Producer, logLevel } from 'kafkajs';

let producer: Producer | null = null;

export async function getKafkaProducer(): Promise<Producer | null> {
  if (producer) return producer;
  const brokers = (process.env.KAFKA_BROKERS || '').split(',').filter(Boolean);
  const clientId = process.env.KAFKA_CLIENT_ID || 'necxa-engagement';
  if (!brokers.length) {
    console.warn('KAFKA_BROKERS not set, kafka producer will be a noop');
    return null;
  }
  const kafka = new Kafka({ clientId, brokers, logLevel: logLevel.NOTHING });
  producer = kafka.producer();
  await producer.connect();
  return producer;
}

export async function sendEvent(topic: string, message: any) {
  const p = await getKafkaProducer();
  if (!p) {
    console.debug('kafka noop send', topic, message);
    return;
  }
  await p.send({ topic, messages: [{ value: JSON.stringify(message) }] });
}
