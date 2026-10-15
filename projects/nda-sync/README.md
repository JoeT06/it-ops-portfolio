# NDA sync to SharePoint

**Status:** Live\
**My role:** Built\
**Stack:** Adobe Acrobat Sign, Power Automate, SharePoint Online

## Problem

Visitor NDAs were signed on paper and filed by hand, with no easy way to track them.

## What it does

Visitors sign the NDA through an Acrobat Sign web form. A scheduled Power Automate flow files every signed NDA in a SharePoint document library:

1. Runs on a short recurrence.
2. Lists all agreements in Acrobat Sign and filters them down to signed NDAs.
3. For each one, gets the signed PDF and checks SharePoint for an existing file.
4. Creates the file only when it isn't already there, so repeat runs don't create duplicates.

![Scheduled NDA sync flow](images/nda-sync-flow.png)

## Why it runs on a schedule

The first version fired on Acrobat Sign's "agreement workflow completed" trigger, pulled the signed document, and created the file in SharePoint. The trigger had limitations, so I rebuilt the flow on a schedule. Every scheduled run sees every agreement, which is why the duplicate check matters.

![First version: trigger-based flow](images/save-signed-nda-flow.png)
