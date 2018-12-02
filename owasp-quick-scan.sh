#!/bin/bash
# Will run OWASP quick scan against a url
set -ou pipefail

CONTAINER_NAME=zap
IS_ZAP_RUNNING=0
REPORTS_FOLDER="$(pwd)/reports"
REPORT_NAME=owasp-quick-scan-report.html
REPORT_PATH="${REPORTS_FOLDER}/${REPORT_NAME}"
PORT=8080
ALERT_LEVEL='Medium'
OPEN_REPORT=0

while getopts "u:l:oh" opt; do
  case $opt in
  u)
      URL_TO_SCAN=$OPTARG
      ;;
  l)
      ALERT_LEVEL=$OPTARG
      ;;
  o)
      OPEN_REPORT=1
      ;;
  h)
    echo "Usage: Security scan [options]"
    echo "  -u URL to scan."
    echo "  -a Alert level to fail the script. Defaults to 'Medium'"
    echo "  -o Open OWASP Report after script run"
    echo ""
    exit
  esac
done

echo "Scanning $URL_TO_SCAN ....."

function check_exit_code {
  if [ "$1" != "0" ]; then
    echo "Something went wrong with '${2}'"
    exit "$1"
  fi
}

function is_zap_running() {
  ZAP_STATUS=$(docker exec zap zap-cli status | grep -c INFO)
  if [[ "${ZAP_STATUS}" == 1 ]]; then IS_ZAP_RUNNING=1; fi
}

function remove_zap_container() {
  docker rm -f "${CONTAINER_NAME}"
}

function run_in_zap_container() {
  ZAP_COMMAND="docker exec ${CONTAINER_NAME} zap-cli --verbose $1"
  echo 'Running...'
  echo "${ZAP_COMMAND}"
  echo ''
  sh -c "${ZAP_COMMAND}"
}

function launch_html_report() {
  open "${REPORT_PATH}"
}

# Check if jq is installed. jq is used to count owasp alerts
if ! [ -x "$(command -v jq)" ]; then
  echo 'Please install jq from https://stedolan.github.io/jq/'
  exit 1
fi

# Make reports folder and set correct permissions where the docker container can write to the volume bind mount
rm -rf "${REPORTS_FOLDER}"
mkdir -p "${REPORTS_FOLDER}"
chmod 777 "${REPORTS_FOLDER}"
check_exit_code $? "with changing permission"

# Start zap container
remove_zap_container
docker run --detach --name "${CONTAINER_NAME}" -u zap -v "${REPORTS_FOLDER}":/zap/reports/:rw \
  -i owasp/zap2docker-stable zap.sh -daemon -host 0.0.0.0 -port "${PORT}" \
  -config api.addrs.addr.name=.* -config api.addrs.addr.regex=true \
  -config api.disablekey=true
  check_exit_code $? "starting container"

# Check that container and zap daemon has started
while [[ "${IS_ZAP_RUNNING}" == 0 ]]; do echo "zap container is starting up"; is_zap_running; sleep 1; done

# Run quick scan in container
# quick-scan will open the URL to make sure it's in the site tree, run an active scan, and will output any found alerts.
# https://github.com/Grunny/zap-cli
run_in_zap_container "quick-scan ${URL_TO_SCAN}"

# Generate report
run_in_zap_container "report -o /zap/reports/${REPORT_NAME} --output-format html"

# Check if report was generated
if [[ ! -e "${REPORT_PATH}" ]]; then
  echo "${REPORT_PATH} should be generated but it is missing"
  remove_zap_container
  exit 1
fi

# Check alerts
ALERT_NUM=$(docker exec "${CONTAINER_NAME}" zap-cli --verbose alerts --alert-level "${ALERT_LEVEL}" -f json | jq length)

if [[ "${OPEN_REPORT}" == 1 ]]; then
  launch_html_report
fi

remove_zap_container

if [[ "${ALERT_NUM}" -gt 0 ]]; then
  echo "${ALERT_NUM} ${ALERT_LEVEL} Alerts found! Please check the Zap Scanning Report ${REPORT_PATH}"
  exit 1
fi

echo "Scan successfully finished with no ${ALERT_LEVEL} alerts"