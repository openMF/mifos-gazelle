# Contributing to Mifos Gazelle
 Thank you for your interest in contributing to the Mifos Gazelle repository! Your contributions are important and will help to improve the project for everyone. Before you begin, please consider the guidelines below.

## Branches

* Main - contains released versions of the Mifos Gazelle product. This should be considered the stable branch.
* Dev - Where all contributions should be raised as PRs, this should be considered as pre-release code
* ... - Individual branches used by contributors for pre-staging or testing but note our reserved branch names.

## Reserved Branch Names and Tags

The following branch names and tags (and derivatives and extensions e.g., releasev1.0) are reserved for use by Mifos Organisation. Any branches created by non-admins with these names will be deleted without notice:

- main
- master
- dev
- development
- sec
- security
- mifos
- release
- rel
- rc
- staging
- prod
- production
- gsoc
- test
- testing

## Releases

Please always contribute to **Dev**. We then compile accepted PRs from Dev into releases within the community the timing of these releases is.

## Getting Started

- View the [README](README.MD) to get your development environment up and running.
- Sign the [Contribution License Agreement](https://mifos.org/about-us/financial-legal/mifos-contributor-agreement/).
- Always follow the [code of conduct](https://mifos.org/resources/community/code-of-conduct/) - this is important to us. We are proud to be open, tolerant and providing a positive environment.
- Introduce yourself or ask a question on the [#mifos-gazelle-dev channel on Slack](https://mifos.slack.com/archives/C059L7BQMMH).
- Find a [Jira](https://mifosforge.jira.com/jira/software/c/projects/GAZ/issues?jql=project%20%3D%20%22GAZ%22%20ORDER%20BY%20created%20DESC) ticket to work on.
- If its is already assigned you are not allowed to take it.  Instead you must ask the person assigned and they may choose to re-assign it to you.
- If its not assigned you can assign it to yourself.  Make sure you keep the status of the ticket up to date and include in comments your progress e.g. screenshots.
- If you need too you can raise a [Jira] ticket on our board for a new feature or enhancement that you want to work on that doesnt have an existing ticket. However its good community spirit to discuss what you are planning in our slack `#mifos-gazelle-dev` first. It may also save you wasting time.
- Make sure you have [Git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git) installed on your machine.
- Fork the repository and clone it locally.

git clone --branch dev https://github.com/openMF/mifos-gazelle.git


- Create a new branch for your contributions
git checkout -b feature-branch-name


## Making Changes

- Before making changes, ensure that you're working on the latest version of the `dev` branch

git pull origin dev


## Committing Changes

- Stage your changes:

git add file-name(s)

- Commit your changes with a descriptive message:

git commit -m "Add feature"

- Push your changes to your forked repository:

git push origin feature-branch-name


## Submitting a Pull Request

- Follow the steps outlined in [GitHub's documentation](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request)
- The following items are mandatory for all Pull Requests.
- (1) Contributor Licence agreement has been signed
- (2) PR title includes the JIRA ticket reference to allow for tracking
- (3) PR Description explains what you have done, it should include testing and scripts
- (4) You declaire if you have used AI and where.  Use of AI is fine but you are expected to have reviewed the output made necessary changes and licence checks and removed any unnecessary AI changes (e.g. removed AI adding of random templates and styles)

## Commit Hygiene (Squash)

We maintain a linear, meaningful git history.

- **One Feature = One PR:** Do not combine unrelated fixes.
- **Squash Requirement:** If your PR contains more than 2 commits, you must squash them.
  - ❌ **Bad History:** `init`, `wip`, `typo`, `fix`, `fix again`
  - ✅ **Good History:** `GAZ-123: Implement data load functionality`

**How to Squash (Step-by-Step Example):**

1. **Start Interactive Rebase:** Run the following command (replace `2` with the number of commits you want to combine):

   ```bash
   git rebase -i HEAD~2
   ```

2. **Edit the Rebase File:** An editor will open listing your recent commits. It will look like this:

   ```text
   pick a1b2c3d Message of the older commit
   pick e4f5g6h Message of the newer commit
   ```

3. **Squash the Commits:** Change `pick` to `squash` (or `s`) for all commits except the first one:

   ```text
   pick a1b2c3d Message of the older commit
   s e4f5g6h Message of the newer commit
   ```

4. **Save and Close:** Save the file and close the editor.

5. **Finalize Message:** A new editor window will appear. Combine or edit the commit messages into a single, meaningful title (e.g., `GAZ-123: Feature description`). Save and close.

6. **Force Push:** Send the changes to your remote repository.
   ```bash
   git push origin branch-name --force-with-lease
   ```


## Code Review

- After submitting your PR, our team will review your changes.
- Address any feedback or requested changes promptly.
- Once approved, your PR will be merged into the `dev` branch.
- Every release we will take the release from the 'dev' branch to the 'main' branch

## After your PR is merged

After your PR has been reviewed any feedback taken on board and merged there are a few things to keep things tidy we like you to do.
- Delete your branch unless you think it will be needed again
- update Jira status to `DONE` if its the last PR you need to raise to address a ticket.  **Do not do this if you will need to raise another PR to fully address the scope or if its still in PR review.**

## Reporting Issues

If you find any bugs or have recommendations for improvements, please feel free to [raise a bug here](https://mifosforge.jira.com/jira/software/c/projects/GAZ/issues?jql=project%20%3D%20%22GAZ%22%20ORDER%20BY%20created%20DESC) with a detailed explanation of issue ideally including steps to reproduce and screenshots/video.

## Contact

- For further assistance or questions regarding contributions, feel free to join our Slack channel [here](https://mifos.slack.com/ssb/redirect).  If you need an invite you can use this [link](https://join.slack.com/t/mifos/shared_invite/zt-3m6x47dgj-iX0Oqv8KS0VGgouNnuJrAg)

Thank you again for your interest in [Mifos Gazelle](https://github.com/openMF/mifos-gazelle)! We look forward to your contributions.
