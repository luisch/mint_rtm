require 'chronic'

# 前提条件
#	繰り返しにする専用のトラッカー == 3 がある
#	繰り返しピリオドを指定する文字列カスタムフィールド == "after" がある
#	CLOSE == 5したとき、GO == 9に戻す。

class RtmHook < Redmine::Hook::Listener

	# TODO 下記は本来パラメーターにしてプラグイン設定で変更できるように。
	STATUS_SETUP=1
	STATUS_CLOSED=[5]
	STATUS_REJECTED=[6]
	STATUS_GO=9
	COPY_TRACKERS=[1]
	REPEATE_TRACKERS=[3]
	ACTIVITY_ID=7

	def controller_issues_new_before_save(context)
		# tweak 担当者がblankなら自動的に自分に置換しといてあげる
		issue = context[:issue]
		issue.author = User.current if issue.author.blank?
	end

	def controller_issues_edit_before_save(context)
		issue = context[:issue]
		issue_close_and_go   context if REPEATE_TRACKERS.include?(issue.tracker.id)
		issue_close_and_copy context if COPY_TRACKERS.include?(issue.tracker.id)
	end
	
	def controller_issues_bulk_edit_before_save(context)
		issue = context[:issue]
		issue_close_and_go   context if REPEATE_TRACKERS.include?(issue.tracker.id)
		issue_close_and_copy context if COPY_TRACKERS.include?(issue.tracker.id)
	end
	
	# チケットをコピーして、開始日・期日だけ置き換えるタイプ
	def issue_close_and_copy(context)
		issue = context[:issue]
		
		#トラッカーが指定で、かつCLOSEされたとき。
		if( STATUS_CLOSED.include?(issue.status.id) )
			cf_after = issue.custom_field_values.detect{
				|c| c.custom_field.name == "after"
			}
			execd = issue.custom_field_values.index{
				|c| c.custom_field.id == 2
			}
			
			begin
				# 開始日を基準に色々考えるです
				next_from = parse_date(cf_after.to_s, Chronic.parse(issue.start_date.to_s))
				next_due =  next_from + (issue.due_date - issue.start_date)
				
				Rails.logger.info(execd)
				
				ic = Issue.new
				ic.init_journal(User.current)
				ic.copy_from( issue )
				ic.status.id = STATUS_SETUP
				ic.start_date = next_from
				ic.due_date = next_due
				ic.fixed_version_id = nil
				Rails.logger.info(ic.custom_field_values)
				ic.custom_field_values[execd].value = nil
				ic.save
				
			rescue
				Rails.logger.info("faild to parsedate")
				#do nothing.
			end
		end
	end
	
	# チケットを繰り返し再利用するタイプ
	def issue_close_and_go(context)
		issue = context[:issue]
		
		#トラッカーが指定で、かつCLOSEされたとき。
		if (STATUS_CLOSED.include?(issue.status.id) || STATUS_REJECTED.include?(issue.status.id))
			cf_after = issue.custom_field_values.detect{
				|c| c.custom_field.name == "after"
			}

			# CLOSEの場合、予定工数に優位な数値が入っていて、かつ作業時間記録が空なら
			# 自動的に作業時間を予定工数と同じものにする
			if STATUS_CLOSED.include?(issue.status.id)
				time_entry = context[:time_entry]
				if( time_entry.nil? && !issue.estimated_hours.blank? && User.current.allowed_to?(:log_time, issue.project) )
					time_entry = TimeEntry.new(:project => issue.project, :issue => issue, :user => User.current, :spent_on => User.current.today )
					if context[:params][:time_entry].blank?
						time_entry.attributes = {
							:hours => issue.estimated_hours,
							:comments => "[copy from estimated_hours]",
							:activity_id => ACTIVITY_ID #TODO
						}
					else
						time_entry.safe_attributes = context[:params][:time_entry] 
						time_entry.hours = issue.estimated_hours
						time_entry.comments << "[copy from estimated_hours]"
					end
					issue.time_entries << time_entry
				else
					time_entry = nil
				end
			end
			
			begin
				# WatchOut日を基準に色々考えるです
				wo = issue.custom_field_values[0] #TODO
				next_wo = parse_date(cf_after.to_s, Chronic.parse(wo.to_s))
				
				#	期限が設定されていて、かつ次の実行日が期限を越えてしまったときはおとなしくそのままcloseする
				if !issue.due_date.nil? 
					due_date = Date::parse(issue.due_date.to_s)
					if( due_date < next_wo )
						Rails.logger.info("next over due")
						return
					end
				end
				if cf_after.to_s.blank?
					# 期限は未設定だが、next_woがnilの場合は、
					# afterがnilで特に続ける必要が無い場合と
					# afterの文字列が間違っている場合がある
					# 前者の場合はそのままcloseする必要がある
					return
				end
				
				issue.save # 一旦保存
				time_entry.save if !time_entry.nil?
				
				wo.value = next_wo.to_s
				issue[:status_id] = STATUS_GO #TODO/GO
				
			rescue
				Rails.logger.info("faild to parsedate")
				#do nothing.
			end
		end
	end
	
	def parse_date(time_str,starting_point)
		# 冒頭がafterで始まっていたら、starting_pointを今日にする
		# 冒頭がeveryで始まっていたorなにも指定が無ければ、starting_pointを引数にする
		if /^[ ]*(after|every)(.*)/ =~ time_str
			starting_point = Time.now if( $1 == "after" )
			time_str = $2
		end
		
		d=[]
		time_str.split(",").each{ |c|
			cc = Chronic.parse(c, :now =>starting_point)
			Rails.logger.info( c + " => " + cc.to_s )
			d << cc.to_date if cc > starting_point
		}
		return d.min
	end

end
