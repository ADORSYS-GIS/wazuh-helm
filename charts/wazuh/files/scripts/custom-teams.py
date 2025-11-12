#!/var/ossec/framework/python/bin/python3
import sys
import json
import requests
import logging

logging.basicConfig(
    filename='/var/ossec/logs/integrations.log',
    level=logging.INFO,
    format='%(asctime)s custom-teams: %(levelname)s %(message)s'
)
log = logging.getLogger('custom-teams')

def load_alert(file_path):
    try:
        with open(file_path, 'r') as f:
            lines = [l.strip() for l in f if l.strip()]
            return json.loads(lines[-1]) if lines else None
    except Exception as e:
        log.error("Failed to load alert %s: %s", file_path, e)
        return None

def find_webhook_url(args):
    # Look for any arg that starts with http and is long (Teams URL)
    for arg in args:
        if arg.startswith('http') and len(arg) > 50:
            return arg
    return None

def build_card(alert):
    rule = alert.get('rule', {})
    agent = alert.get('agent', {})
    level = rule.get('level', 0)
    return {
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": "0078D7" if int(level) < 10 else "FF0000",
        "summary": "Wazuh Alert",
        "sections": [{
            "activityTitle": f"Wazuh Alert – Level {level}",
            "facts": [
                {"name": "Time",  "value": alert.get('timestamp', 'N/A')},
                {"name": "Agent", "value": f"{agent.get('name','N/A')} (ID: {agent.get('id','N/A')})"},
                {"name": "Rule",  "value": rule.get('description', 'N/A')}
            ],
            "markdown": True
        }]
    }

def send_to_teams(url, card):
    try:
        r = requests.post(url, json=card, headers={"Content-Type": "application/json"}, timeout=10)
        r.raise_for_status()
        log.info("Sent to Teams – %s", r.status_code)
    except Exception as e:
        log.error("Send failed: %s", e)

def main():
    log.info("Received args: %s", sys.argv)

    if len(sys.argv) < 2:
        log.error("No arguments received")
        sys.exit(1)

    alert_file = sys.argv[1]
    webhook_url = find_webhook_url(sys.argv[2:])  # Search from arg 2 onward

    if not webhook_url:
        log.error("No valid webhook URL found in args: %s", sys.argv[2:])
        sys.exit(1)

    log.info("Using alert: %s → %s", alert_file, webhook_url)

    alert = load_alert(alert_file)
    if not alert:
        sys.exit(1)

    card = build_card(alert)
    send_to_teams(webhook_url, card)

if __name__ == "__main__":
    main()