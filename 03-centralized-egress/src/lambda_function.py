import json
import urllib.request

def lambda_handler(event, context):
    url = 'https://api.github.com/'
    req = urllib.request.Request(
        url,
        headers={'User-Agent': 'AWS-Lambda-Centralized-Egress-Test'}
    )
    with urllib.request.urlopen(req, timeout=10) as response:
        status_code = response.getcode()
        print(f"URL: {url}")
        print(f"Status Code: {status_code}")
        return {
            'statusCode': status_code,
            'body': json.dumps({'url': url, 'status': status_code})
        }
