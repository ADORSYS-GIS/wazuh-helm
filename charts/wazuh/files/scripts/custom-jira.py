#!/var/ossec/framework/python/bin/python3
import sys
import json
import requests
import logging

# Configure logging to write to /var/ossec/logs/integrations.log
logging.basicConfig(
    filename='/var/ossec/logs/integrations.log',
    level=logging.INFO,
    format='%(asctime)s custom-jira: %(levelname)s %(message)s'
)
logger = logging.getLogger('custom-jira')

def load_alert_data(file_path):
    """Load alert data from the JSON file."""
    try:
        with open(file_path, 'r') as file:
            lines = file.readlines()
            if not lines:
                logger.error(f"File '{file_path}' is empty.")
                return None
            last_line = lines[-1].strip()
            return json.loads(last_line)
    except FileNotFoundError:
        logger.error(f"File '{file_path}' not found.")
        return None
    except json.JSONDecodeError:
        logger.error(f"Failed to parse the last line '{file_path}' as JSON.")
        return None

def prepare_jira_payload(alert_data):
    """Prepare the payload for Jira based on Wazuh alert data."""
    summary = alert_data.get("rule", {}).get("description", "Wazuh Alert")
    description = (
        f"Alert ID: {alert_data.get('id', 'N/A')}\n"
        f"Agent ID: {alert_data.get('agent', {}).get('id', 'N/A')}\n"
        f"Rule ID: {alert_data.get('rule', {}).get('id', 'N/A')}\n"
        f"Rule Level: {alert_data.get('rule', {}).get('level', 'N/A')}\n"
        f"Rule Description: {alert_data.get('rule', {}).get('description', 'N/A')}\n"
        f"Groups: {', '.join(alert_data.get('rule', {}).get('groups', ['N/A']))}\n"
        f"Data Title: {alert_data.get('data', {}).get('title', 'N/A')}\n"
        f"Data File: {alert_data.get('data', {}).get('file', 'N/A')}\n"
        f"Details: {alert_data.get('full_log', 'No additional details')}"
    )

    payload = {
        'data': {
            "project": {"key": "WAZUH"},
            "summary": f"Wazuh Alert: {summary}",
            "description": description,
            "issuetype": {"name": "Task"}
        }
    }
    
    return payload

def send_webhook(url, api_key, payload):
    """Send the webhook request to Jira."""
    headers = {
        "Content-type": "application/json",
        "X-Automation-Webhook-Token": api_key
    }
    try:
        response = requests.post(url, headers=headers, json=payload)
        response.raise_for_status()
        logger.info("Webhook sent successfully!")
        logger.info(f"Response: {response.text}")
    except requests.exceptions.RequestException as e:
        logger.error(f"Error sending webhook: {e}")
        if 'response' in locals():
            logger.error(f"Response: {response.text}")

def main():
    # Check if enough arguments are provided
    if len(sys.argv) != 4:
        logger.error(f"Expected 3 arguments (alert_file, api_key, hook_url), got {len(sys.argv) - 1}")
        logger.error(f"Usage: {sys.argv[0]} <alert_file> <api_key> <hook_url>")
        sys.exit(1)

    # Map sys.argv to variables per ossec.conf
    alert_file = sys.argv[1]  # First argument: alert file path
    api_key = sys.argv[2]     # Second argument: api_key from ossec.conf
    hook_url = sys.argv[3]    # Third argument: hook_url from ossec.conf

    # Load alert data using the provided file path
    alert_data = load_alert_data(alert_file)
    if not alert_data:
        sys.exit(1)

    # Prepare the Jira payload
    payload = prepare_jira_payload(alert_data)
    logger.info("Prepared payload: %s", json.dumps(payload, indent=2))

    # Send the webhook using the provided URL and token
    send_webhook(hook_url, api_key, payload)

if __name__ == "__main__":
    main()