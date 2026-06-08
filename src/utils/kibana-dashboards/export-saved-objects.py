# Steps to run the script
# 1. Create virtual environment using `python<version> -m venv <virtual-environment-name>`
# 2. Activate virtual environment using `source <virtual-environment-name>/bin/activate`
# 3. Run `pip install requests logger python-dotenv`
# 4. Add auth Token and Kibana URL in .env file
# 5. Run `python export-saved-objects.py`
import requests
import logging
import os
import json
from dotenv import load_dotenv

load_dotenv()

_logger = logging.getLogger(__name__)


KIBANA_URL = os.environ.get("KIBANA_URL")

VERIFY = False

export_types = [
    "visualization",
    "index-pattern",
    "dashboard",
    "lens",
    "search",
]

# Getting saved objects
def get_saved_objects(type):
    url = KIBANA_URL + "api/saved_objects/_find"

    params = {"type": type}
    headers = {
        "kbn-xsrf": "true",
        "Authorization": "Basic " + os.environ.get("AUTH"),
    }
    try:
        response = requests.request(
            "GET", url, headers=headers, params=params, verify=VERIFY
        )
        return response
    except BaseException as e:
        _logger.info(e)


# Exporting specific id saved object
def create_saved_objects(type, object_id):
    url = KIBANA_URL + "api/saved_objects/_export"
    payload = json.dumps({"objects": [{"type": type, "id": str(object_id)}]})
    headers = {"kbn-xsrf": "true", "Content-Type": "application/json"}
    try:
        response = requests.request(
            "POST", url, headers=headers, data=payload, verify=VERIFY
        )
        return response
    except BaseException as e:
        _logger.info(e)


# Creating directory
def create_dir(type):
    try:
        os.mkdir(type)
        return type
    except FileExistsError as e:
        _logger.info(e)


# Saving saved objects to the respective directory
def save_all_objects(type, object_id, title, dir_name):
    response = create_saved_objects(type, object_id)
    title = title.replace("/", "")
    open_file = f"{dir_name}/{title}"
    try:
        file = open(open_file + ".ndjson", "wb")
        file.write(response.content)
    finally:
        file.close()


# Driver function
def export_saved_objects():
    for type in export_types:
        response = get_saved_objects(type)
        if response is not None:
            try:
                saved_objects = response.json()["saved_objects"]
                dir_name = create_dir(type)
                for obj in saved_objects:
                    type, object_id, title = (
                        obj["type"],
                        obj["id"],
                        obj["attributes"]["title"],
                    )
                    save_all_objects(type, object_id, title, dir_name)
            except BaseException as e:
                _logger.info(e)


if __name__ == "__main__":
    _logger.info("Exporting types ", export_types)
    export_saved_objects()
