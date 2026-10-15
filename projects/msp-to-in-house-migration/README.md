# MSP to in-house migration

**Status:** Complete\
**My role:** Assisted on the full migration, then took ownership of the tools

## What moved in-house

EDR, MDR, email security, backup and disaster recovery, RMM, and monitoring, all previously run by a managed service provider.

## My part

- Assisted on every part of the migration.
- Took the migrated tools onto my own plate afterward. I now handle security alert triage, EDR quarantine review, email quarantine, agent deployment through RMM, and phishing simulation campaigns.

## Removing the old remote-access client

The old tenant's ScreenConnect client had to come off endpoints before the new RMM's remote-access client went on. Uninstalling by a fixed MSI product code did nothing, because ScreenConnect generates a unique product code for each instance.

[Force-Remove-ScreenConnect.ps1](scripts/Force-Remove-ScreenConnect.ps1) finds the client by name instead. Removal is scoped to one instance ID unless `-AllInstances` is passed, so other ScreenConnect instances on the machine stay installed. With no parameters, the script lists the instances on the machine and removes nothing.

```powershell
.\Force-Remove-ScreenConnect.ps1                               # list instances, remove nothing
.\Force-Remove-ScreenConnect.ps1 -InstanceId 0123456789abcdef  # remove one instance
.\Force-Remove-ScreenConnect.ps1 -AllInstances                 # remove every instance
```

It removes the target in eight steps:

1. Finds matching ScreenConnect products in the 64-bit and WOW6432Node uninstall registry keys.
2. Stops the services. Each service name includes the instance ID.
3. Kills the processes. Process names don't carry the instance ID, so instance mode matches on the executable's path.
4. Deletes the services, then runs `msiexec /x` against each product code it found, with a verbose log per product.
5. Removes orphaned Add/Remove Programs entries and the `Installer\Products` cache key.
6. Removes ScreenConnect scheduled tasks and leftover service registry keys.
7. Deletes the install folders by wildcard.
8. Reports anything still present: services, uninstall entries, and folders.

Each step runs through a wrapper that logs a failure and moves on, so one locked file doesn't stop the cleanup. A reboot before installing the new client releases any locked handles.
