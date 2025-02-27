#
# Copyright 2018-2019 Red Hat, Inc.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
"""Tests kafka message handler."""
import asyncio
import io
import json
import tarfile
from unittest import IsolatedAsyncioTestCase
from unittest.mock import Mock
from unittest.mock import patch

from asgiref.sync import sync_to_async
from asynctest import CoroutineMock
from django import db

import processor.report_consumer as msg_handler
from api.models import Report

# from django.test import TestCase


def create_tar_buffer(files_data, encoding="utf-8", meta_encoding="utf-8"):
    """Generate a file buffer based off a dictionary."""
    if not isinstance(files_data, (dict,)):
        return None
    if not all(isinstance(v, (str, dict)) for v in files_data.values()):
        return None
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w:gz") as tar_file:
        for file_name, file_content in files_data.items():
            if "metadata.json" in file_name:
                file_buffer = io.BytesIO(json.dumps(file_content).encode(meta_encoding))
            elif file_name.endswith("json"):
                file_buffer = io.BytesIO(json.dumps(file_content).encode(encoding))
            elif file_name.endswith("csv"):
                file_buffer = io.BytesIO(file_content.encode(encoding))
            else:
                return None
            info = tarfile.TarInfo(name=file_name)
            info.size = len(file_buffer.getvalue())
            tar_file.addfile(tarinfo=info, fileobj=file_buffer)
    tar_buffer.seek(0)
    return tar_buffer.getvalue()


class KafkaMsg:  # pylint:disable=too-few-public-methods
    """Create a kafka msg."""

    def __init__(self, topic, url):
        """Initialize the message."""
        self._topic = topic
        value_dict = {"url": url, "rh_account": "1234", "request_id": "234332"}
        value_str = json.dumps(value_dict)
        self._value = value_str.encode("utf-8")

    def topic(self):
        """Returns topic"""
        return self._topic

    def value(self):
        """Returns value"""
        return self._value


class KafkaMsgHandlerTest(IsolatedAsyncioTestCase):
    """Test Cases for the Kafka msg handler."""

    def setUp(self):
        """Create test setup."""
        self.payload_url = "http://insights-upload.com/q/file_to_validate"
        self.report_consumer = msg_handler.ReportConsumer()

    def tearDown(self):
        """Remove test setup."""
        db.connections.close_all()

    def test_format_message_no_account_report(self):
        """Test format message without account or report id."""
        msg = msg_handler.format_message("p", "m")
        self.assertEqual(msg, "p - m")

    def test_unpack_consumer_record(self):
        """Test format message without account or report id."""
        fake_record = KafkaMsg(msg_handler.MKT_TOPIC, "http://internet.com")
        msg = self.report_consumer.unpack_consumer_record(fake_record)
        self.assertEqual(msg, {"url": "http://internet.com", "rh_account": "1234", "request_id": "234332"})

    def test_unpack_consumer_record_not_json(self):
        """Test format message without account or report id."""
        fake_record = KafkaMsg(msg_handler.MKT_TOPIC, "http://internet.com")
        fake_record._value = "not json".encode()

        with self.assertRaises(msg_handler.MKTKafkaMsgException):
            self.report_consumer.unpack_consumer_record(fake_record)

    async def save_and_ack(self):
        """Test the save and ack message method."""
        self.report_consumer.consumer = Mock()
        self.report_consumer.consumer.commit = CoroutineMock()
        mkt_msg = KafkaMsg(msg_handler.MKT_TOPIC, self.payload_url)
        # test happy case
        with patch(
            "processor.report_consumer.ReportConsumer.unpack_consumer_record",
            return_value={"account": "8910", "request_id": "1234"},
        ):
            await self.report_consumer.save_message_and_ack(mkt_msg)
            report = await sync_to_async(Report.objects.get)(account="8910")
            self.assertEqual(json.loads(report.upload_srv_kafka_msg), {"account": "8910", "request_id": "1234"})
            self.assertEqual(report.state, Report.NEW)

        # test no rh_account or request_id
        with patch("processor.report_consumer.ReportConsumer.unpack_consumer_record", return_value={"foo": "bar"}):
            await self.report_consumer.save_message_and_ack(mkt_msg)
            with self.assertRaises(Report.DoesNotExist):
                await sync_to_async(Report.objects.get)(upload_srv_kafka_msg=json.dumps({"foo": "bar"}))

        # test general exception
        def raise_error():
            """Raise a general error."""
            raise Exception("Test")

        self.report_consumer.consumer.commit = CoroutineMock(side_effect=raise_error)
        with patch(
            "processor.report_consumer.ReportConsumer.unpack_consumer_record",
            return_value={"rh_account": "1112", "request_id": "1234"},
        ):
            await self.report_consumer.save_message_and_ack(mkt_msg)
            report = await sync_to_async(Report.objects.get)(account="1112")
            self.assertEqual(json.loads(report.upload_srv_kafka_msg), {"rh_account": "1112", "request_id": "1234"})
            self.assertEqual(report.state, Report.NEW)

    def test_save_and_ack_success(self):
        """Test the async save and ack function."""
        event_loop = asyncio.new_event_loop()
        asyncio.set_event_loop(event_loop)
        coro = asyncio.coroutine(self.save_and_ack)
        event_loop.run_until_complete(coro())
        event_loop.close()
