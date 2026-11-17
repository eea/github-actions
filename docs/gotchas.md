# Gotchas

Platform quirks found the hard way. Add an entry when something cost time and is not
obvious from the code.

## Testing GitHub notifications: check the mail filters before the code

**Found:** 2026-11-17, while testing the `betterleaks` `mention-author` feature.

A commit comment from `github-actions[bot]` that @mentioned the commit author seemed
to send no notification, and the feature was removed. The notification had been
delivered: Gmail filed GitHub's emails under the **Updates** tab, and the failed-workflow
notification was there too. The feature was restored.

Before deciding that a GitHub notification was not sent:

- look in every mail tab and folder (Gmail Updates/Promotions, filters, spam) and in
  https://github.com/notifications;
- allow for delay: some notifications arrived minutes after the comment;
- test with a mention from an account other than the recipient's. GitHub never notifies
  you about your own comments. A mention from `github-actions[bot]` (the job's
  `GITHUB_TOKEN`) does notify the person mentioned, including the person whose push
  started the workflow.

## Fine-grained tokens on `eea` can need org approval

A fine-grained personal access token with resource owner `eea` returned
`403 Resource not accessible by personal access token` (and saw no private `eea`
repositories) until it was allowed on the organization side; the same token then worked
without changes. A fine-grained token that is pending approval, or blocked by the
organization's token policy, has no access to `eea` repositories. Check the token's page
and the organization's personal access token settings before changing its permissions.
