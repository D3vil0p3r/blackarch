name: "🪞 Mirror submission"
description: "Submit a new mirror to be added to the BlackArch mirror list."
title: "Mirror submission: MIRROR_URL"
labels: ["type::mirror-submission"]
body:
  - type: "markdown"
    attributes:
      value: |
        <details>
        <summary><strong>📌 Click here to review requirements for mirror submissions</strong></summary>

        #### **❗ Reject Reasons (will not be accepted)**

        - <span style="color:red"><strong>🚫 Unstable or unreliable mirrors</strong></span>  
          Mirrors must maintain reasonable uptime. Servers with frequent downtime or inconsistent availability will not be accepted.

        - <span style="color:red"><strong>🚫 Slow sync frequency</strong></span>  
          Mirrors must sync with the upstream BlackArch repository at least once every 24 hours.

        - <span style="color:red"><strong>🚫 Incomplete sync</strong></span>  
          Mirrors must host the full BlackArch repository. Partial mirrors are not accepted.

        - <span style="color:red"><strong>🚫 Missing corresponding PR in blackarch-site</strong></span>  
          Both repositories must be updated simultaneously. Submissions missing the `blackarch-site` PR will be held until it is provided.
          You must edit [`mirrors/mirror.lst`](https://github.com/BlackArch/blackarch/blob/master/mirrors/mirror.lst) in this repository
          **and** [`data/blackarch-mirrorlist`](https://github.com/BlackArch/blackarch-site/blob/master/blackarch-mirrorlist)
          in the [blackarch-site repository](https://github.com/BlackArch/blackarch-site), and link both PRs in your submission.

        - <span style="color:red"><strong>🚫 No valid operator contact</strong></span>  
          The BlackArch team must be able to reach the mirror operator for maintenance or takedown requests.

        **Before submitting, please confirm that your mirror meets all of the requirements above.**

        </details>

  - type: "input"
    id: "mirror-url"
    attributes:
      label: "Mirror URL"
      description: "Please provide the full URL of the mirror (e.g., `https://mirror.example.com/blackarch/`)."
      placeholder: "https://mirror.example.com/blackarch/"
    validations:
      required: true

  - type: "input"
    id: "mirror-country"
    attributes:
      label: "Country / Region"
      description: "Please indicate the country or region where the mirror is hosted (e.g., `DE`, `US - East Coast`)."
      placeholder: "DE"
    validations:
      required: true

  - type: "input"
    id: "mirror-bandwidth"
    attributes:
      label: "Available bandwidth"
      description: "Please indicate the available bandwidth for the mirror (e.g., `1 Gbps`)."
      placeholder: "1 Gbps"
    validations:
      required: true

  - type: "input"
    id: "sync-frequency"
    attributes:
      label: "Sync frequency"
      description: "How often does the mirror sync with the upstream repository?"
      placeholder: "Every 6 hours"
    validations:
      required: true

  - type: "input"
    id: "operator-contact"
    attributes:
      label: "Operator contact"
      description: "Please provide a contact email or handle for the mirror operator. This will be used by the BlackArch team for maintenance or takedown requests."
      placeholder: "admin@example.com"
    validations:
      required: true

  - type: "input"
    id: "blackarch-site-pr"
    attributes:
      label: "Corresponding blackarch-site PR"
      description: |
        Please link the corresponding pull request you have opened in the
        [blackarch-site repository](https://github.com/BlackArch/blackarch-site).
        Both PRs are **mandatory** and must be submitted together.

        Each PR must edit the following files respectively:
        - **This repository:** [`mirrors/mirror.lst`](https://github.com/BlackArch/blackarch/blob/master/mirrors/mirror.lst)
        - **blackarch-site:** [`data/blackarch-mirrorlist`](https://github.com/BlackArch/blackarch-site/blob/master/data/blackarch-mirrorlist)
      placeholder: "https://github.com/BlackArch/blackarch-site/pull/XXXX"
    validations:
      required: true

  - type: "textarea"
    id: "additional-context"
    attributes:
      label: "Additional context"
      description: "Add any other relevant information about the mirror here (e.g., IPv6 support, HTTPS-only, sponsoring organization)."
    validations:
      required: false

  - type: "checkboxes"
    id: "sanity-check"
    attributes:
      label: "I confirm that this submission meets BlackArch mirror requirements"
      options:
        - label: "I assert that this mirror is not a [duplicate of an existing submission](https://github.com/BlackArch/blackarch/pulls?q=is%3Aopen+label%3Atype%3A%3Amirror-submission)."
          required: true
        - label: "I assert that the mirror syncs at least once every 24 hours and hosts the full BlackArch repository."
          required: true
        - label: "I assert that I have opened a corresponding PR in [BlackArch/blackarch-site](https://github.com/BlackArch/blackarch-site) editing `data/blackarch-mirrorlist`, and have linked it above."
          required: true
        - label: "I understand that the BlackArch team may contact me regarding this mirror and that I am responsible for its maintenance."
          required: true
        - label: "I assert that I have read the [Arch Linux Code of Conduct](https://terms.archlinux.org/docs/code-of-conduct/) and agree to abide by it."
          required: true
