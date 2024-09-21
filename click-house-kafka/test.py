from kafka import KafkaProducer
from faker import Faker
import json
from time import sleep
import random
import uuid
from datetime import datetime

print("All modules loaded")

producer = KafkaProducer(bootstrap_servers=['kafka1:9093'])
faker = Faker()


class DataGenerator(object):
    @staticmethod
    def get_customer_data(index):
        customer_data = {
            "customer_id": str(index + 1),  # Set customer_id to index + 1
            "name": faker.name(),
            "state": faker.state(),
            "city": faker.city(),
            "email": faker.email(),
            "created_at": datetime.now().isoformat(),
            "ts": str(datetime.now().timestamp()),
        }
        return customer_data


def initital_push():
    for i in range(5):
        # Generate and send customer data
        customer_data = DataGenerator.get_customer_data(i)
        customer_payload = json.dumps(customer_data).encode("utf-8")
        producer.send('customers', customer_payload)
        print("Customer Payload:", customer_payload)
        sleep(1)


def manual_push():
    customer_data = {
        "customer_id": "3",
        "name": "Joseph**",
        "state": "Connecticut",
        "city": "Lake Natalie",
        "email": "pedro24@example.com",
        "created_at": "2024-09-18T22:40:20.703513",
        "ts": "1726699220.703563"
    }
    customer_payload = json.dumps(customer_data).encode("utf-8")
    producer.send('customers', customer_payload)
    print("Customer Payload:", customer_payload)
    sleep(1)


#manual_push()
initital_push()