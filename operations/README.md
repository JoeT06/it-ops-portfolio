# Day-to-day ownership

Areas I run as part of the role, outside of project work.

## Network

- Administer the UniFi network: controller, 5 switches, and 14 access points covering office, warehouse, and production areas.
- First responder when network gear goes down.
- During an ISP fiber cut, the dual-WAN failover my manager and I configured on the firewall kept the site online on the backup circuit.
- Scripts that switch a Windows device between the main and IoT Wi-Fi networks: [Connect-MainWifi.ps1](scripts/Connect-MainWifi.ps1) and [Connect-IotWifi.ps1](scripts/Connect-IotWifi.ps1). Each prompts for the passphrase, builds a WLAN profile, adds it with `netsh`, and connects. No passphrase is stored in the script.

## ERP administration

- Primary admin for Microsoft Dynamics 365 Business Central. Users across the company come to me for it.
- Rebuilt user permissions in Business Central around least privilege.

## Microsoft 365

- Delegated admin for Microsoft 365 and Entra ID across two tenants.
- Built Power Automate flows for business processes. See the [visitor sign-in kiosk](../projects/visitor-sign-in-kiosk/) and [NDA sync](../projects/nda-sync/).

## Endpoints and mobile devices

- **Scalefusion:** enrolled Samsung tablets and built a lobby kiosk device profile.
- **SureMDM:** own the platform that manages the warehouse scanners.
- **FOG:** workstation imaging over PXE, including troubleshooting PXE boot on a 2-in-1 with no onboard NIC through a USB-C adapter.

## Servers

Windows and Linux servers running as Hyper-V VMs.

## Meeting rooms

Configured the Microsoft Teams Rooms devices for a meeting room overhaul and installed them with my manager.

## Label printing

Assisted with moving label printing from BarTender Cloud to an on-prem deployment. Put the label printers on the network: wired for models that can't be configured over wireless, Wi-Fi for the rest. Recommended moving the production dashboard TVs and some label printers to Ethernet.

## Security operations

- Triage security alerts and review EDR quarantine.
- Run phishing simulation campaigns on the security awareness training platform.
- Manage email security quarantine.

## Support

Tier II escalation point for the help desk.
