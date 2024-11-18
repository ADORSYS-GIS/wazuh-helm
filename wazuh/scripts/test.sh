#!/usr/bin/env bash

set -ex

echo "Writing script into /gen_sh.sh"
echo "#!/usr/bin/env bash\n\nset -ex\n\n# Generate Root CA\necho \"Root CA\"\nopenssl genrsa -out root-ca-key.pem 2048\nopenssl req -days 3650 -new -x509 -sha256 -key root-ca-key.pem -out root-ca.pem -subj \"/C=DE/L=Bayern/O=Adorsys/CN=root-ca\"\n\n# Function to generate certificates for different contexts\ngenerate_cert() {\n  local CONTEXT=$1\n  shift\n  local DOMAINS=(\"$@\")\n\n  echo \"* Generating certificate for context: $CONTEXT\"\n\n  # Generate a private key\n  echo \"create: ${CONTEXT}-key-temp.pem\"\n  openssl genrsa -out \"${CONTEXT}-key-temp.pem\" 2048\n\n  echo \"create: ${CONTEXT}-key.pem\"\n  openssl pkcs8 -inform PEM -outform PEM -in \"${CONTEXT}-key-temp.pem\" -topk8 -nocrypt -v1 PBE-SHA1-3DES -out \"${CONTEXT}-key.pem\"\n\n  echo \"create: ${CONTEXT}.csr\"\n\n  # Use OpenSSL to generate the CSR directly from stdin\n  openssl req -new -days 3650 -key \"${CONTEXT}-key.pem\" -out \"${CONTEXT}.csr\" -config <(\n    cat <<EOL\n[req]\ndefault_bits = 2048\nprompt = no\ndefault_md = sha256\ndistinguished_name = dn\nreq_extensions = req_ext\n\n[dn]\nC = DE\nL = Bayern\nO = Adorsys\nCN = ${DOMAINS[0]}\n\n[req_ext]\nsubjectAltName = @alt_names\n\n[alt_names]\nEOL\n    for i in \"${!DOMAINS[@]}\"; do\n      echo \"DNS.$((i + 1)) = ${DOMAINS[$i]}\"\n    done\n  )\n\n  echo \"create: ${CONTEXT}.pem\"\n  openssl x509 -req -days 3650 -in \"${CONTEXT}.csr\" -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -sha256 -out \"${CONTEXT}.pem\"\n\n  echo \"Certificate for ${CONTEXT} created: ${CONTEXT}.pem\"\n}\n\n# Generate certificates\ngenerate_cert \"indexer\" \\\n    \"*.wazuh-indexer\" \\\n    \"wazuh-indexer\" \\\n    \"*.wazuh-indexer-api\" \\\n    \"wazuh-indexer-api\"\n\ngenerate_cert \"server\" \\\n    \"*.wazuh-manager\" \\\n    \"wazuh-manager\" \\\n    \"*.wazuh\" \\\n    \"wazuh\"\n\ngenerate_cert \"dashboard\" \\\n    \"*.wazuh-dashboard\" \\\n    \"wazuh-dashboard\"\n\ngenerate_cert \"admin\" \"admin\"\n\nrm *.temp.pem" > gen_sh.sh
bash gen_sh.sh