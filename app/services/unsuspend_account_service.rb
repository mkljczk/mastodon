# frozen_string_literal: true

class UnsuspendAccountService < BaseService
  def call(account)
    @account = account

    unsuspend!
    refresh_remote_account!

    return if @account.nil?

    merge_into_home_timelines!
    merge_into_list_timelines!
    Admin::MediaPublicationWorker.perform_async(account.id)
  end

  private

  def unsuspend!
    @account.unsuspend! if @account.suspended?
  end

  def refresh_remote_account!
    return if @account.local?

    # While we had the remote account suspended, it could be that
    # it got suspended on its origin, too. So, we need to refresh
    # it straight away so it gets marked as remotely suspended in
    # that case.

    @account.update!(last_webfingered_at: nil)
    @account = ResolveAccountService.new.call(@account)

    # Worth noting that it is possible that the remote has not only
    # been suspended, but deleted permanently, in which case
    # @account would now be nil.
  end

  def distribute_update_actor!
    return unless @account.local?

    account_reach_finder = AccountReachFinder.new(@account)

    ActivityPub::DeliveryWorker.push_bulk(account_reach_finder.inboxes) do |inbox_url|
      [signed_activity_json, @account.id, inbox_url]
    end
  end

  def merge_into_home_timelines!
    @account.followers_for_local_distribution.find_each do |follower|
      FeedManager.instance.merge_into_home(@account, follower)
    end
  end

  def merge_into_list_timelines!
    @account.lists_for_local_distribution.find_each do |list|
      FeedManager.instance.merge_into_list(@account, list)
    end
  end

  def signed_activity_json
    @signed_activity_json ||= Oj.dump(serialize_payload(@account, ActivityPub::UpdateSerializer, signer: @account))
  end
end
