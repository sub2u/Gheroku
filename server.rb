require 'sinatra'
require 'json'
require 'rufus-scheduler'
require 'rack/session/dalli'
require 'mandrill'
require 'rest_client'
require 'time'
require 'heroku-api'

$mandrill = Mandrill::API.new ENV['MANDRILL_API_KEY']
$heroku = Heroku::API.new(:api_key => "#{ENV['HEROKU_API_KEY']}")

memcache_url = 'dev.cb.buildtool.com'

use Rack::Session::Dalli, :memcache_server => memcache_url, :expire_after => 3600, :namespace => "github-hook"
$cache = Dalli::Client.new(memcache_url, :namespace => "github-hook")

existing_data = $cache.get('configured_projects')
if existing_data.nil?
  $cache.set('configured_projects', [])
end



def protected!
  unless authorized?
    response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
    throw(:halt, [401, "Oops... we need your login name & password\n"])
  end
end

def authorized?
  @auth ||=  Rack::Auth::Basic::Request.new(request.env)
  usr,pwd = 'admin', 'gitG1r'
  @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [usr,pwd]
end

set :port, 3001
$deploy_bucket = []
# @launch_branch_name = 'launch'
# @pending_deploy = false
$active_deploy = false

# @git_appname = nil
# @heroku_appname = nil
# @folder_name = nil
# @git_account = 'LiftOffLLC'

get '/' do
  logger.info "Existing data in cache: #{$cache.get_multi('configured_projects')}"
  erb :list
end

get '/get_existing_conf' do
  $cache.get('configured_projects').to_json
end

delete '/exiting_config' do
  content_type :json
  in_mem = JSON.parse($cache.get('configured_projects').to_json)
  in_mem = in_mem.reject {|p| p["git_appname"].to_s == params["git_appname"].to_s}
  $cache.set("configured_projects", in_mem)
  {:success => true}.to_json
end

put '/update_branch' do
  content_type :json
  input_hash = JSON.parse(request.body.read)

  logger.info "Updating the branch name"
  in_mem = JSON.parse($cache.get('configured_projects').to_json)

  in_mem.each{|app|
    if app["git_appname"] == input_hash["git_appname"]
      if !app["sub_projects"].nil? && app["sub_projects"]
        app["subproj_configs"].each{ |sub_app|
          if sub_app["heroku_appname"] == input_hash["heroku_appname"]
            logger.info("Updated sub_project branch name")
            sub_app["branch"] = input_hash["branch"]
            sub_app["report_to"] = input_hash["report_to"]
          end
        }
      else
        app["branch"] = input_hash["branch"]
        app["report_to"] = input_hash["report_to"]
      end
    end
  }
  logger.info "Done with update, new hash is #{in_mem.inspect}"

  $cache.set("configured_projects", in_mem)
  {:success => true}.to_json
end

post '/new_form' do
  content_type :json
  input_hash = JSON.parse(request.body.read)

  logger.info "New Project Config is: #{input_hash}"
  in_mem = $cache.get('configured_projects')
  input_data = input_hash["formdata"]

  if input_data["sub_projects"]
    logger.info "sub projects exist"
    in_mem.push({"git_account" => input_data["git_account"], "sub_projects" => true, "subproj_configs" => input_data["total"], "git_appname" => input_data["git_appname"]})
  else
    logger.info "single app, no sub-projects exist"
    in_mem.push({"git_account" => input_data["git_account"], "git_appname" =>input_data["git_appname"], "heroku_appname" => input_data["heroku"], "branch" => input_data["branch"], "report_to" => input_data["report_to"]})
  end
  $cache.set("configured_projects", in_mem)
end

post '/payload' do
  payload_data = JSON.parse(request.body.read)

  logger.warn "Received data from Git web-hook: #{payload_data.inspect}"
  in_mem = JSON.parse($cache.get('configured_projects').to_json)
  is_configured = in_mem.select {|p| p["git_appname"].to_s.downcase == payload_data["repository"]["name"].to_s.downcase}

  if is_configured.length > 0
    to_deploy = is_configured[0]
    logger.info "Project Configuration Exists: #{to_deploy}"

    #11 is the fixed position that would have ref/heads/xxx
    branch_committedto = payload_data["ref"].slice(11,payload_data["ref"].length)
    logger.info "Code committed to branch: #{branch_committedto}"

    if !to_deploy["sub_projects"].nil? && to_deploy["sub_projects"]
      logger.info "subprojects found"

      project = to_deploy["subproj_configs"].select{ |q| branch_committedto == q["branch"].to_s }
      logger.info " The sub-project detail is#{project}"

      if project.length > 0
        utc = Time.new.to_i
        project[0][:last_build] = utc*1000
        project[0][:sha] = payload_data["head_commit"]["id"]
        project[0][:last_commit] = payload_data["head_commit"]["message"]
        $cache.set("configured_projects", in_mem)

        logger.info "Heroku repo found, building starts!! #{utc}"

        $deploy_bucket.unshift({:git_account=>to_deploy["git_account"], :launch_branch_name=>project[0]["branch"], :git_appname=>to_deploy["git_appname"], :heroku_appname=>project[0]["heroku_appname"], :folder_name=>project[0]["folder_name"], :report_to=>project[0]["report_to"], :last_build=>project[0][:last_build], :last_commit=>project[0][:last_commit], :sha=>project[0][:sha]})
        logger.info "================================== #{$deploy_bucket[0]}"
        # launch_hook
      else
        logger.info "Code pushed to non launch, no need to deploy"
      end

    else #Doesnt contain sub-projects
      logger.info "single app, no subprojects"
      if branch_committedto == to_deploy["branch"]
        utc = Time.new.to_i
        to_deploy[:last_build] = utc*1000
        to_deploy[:sha] = payload_data["head_commit"]["id"]
        to_deploy[:last_commit] = payload_data["head_commit"]["message"]
        $deploy_bucket.unshift({:git_account=>to_deploy["git_account"], :launch_branch_name=>to_deploy["branch"], :git_appname=>to_deploy["git_appname"], :heroku_appname=>to_deploy["heroku_appname"], :folder_name=>nil, :report_to=>to_deploy["report_to"], :last_build=>to_deploy[:last_build], :last_commit=>to_deploy[:last_commit], :sha=>to_deploy[:sha]})
        logger.info "================================== #{$deploy_bucket[0]}"
        $cache.set("configured_projects", in_mem)
        logger.info "Heroku repo found, building starts!!"
        # launch_hook
      else
        logger.error "Pushed to non launch, no need to deploy"
      end
    end
  else
    logger.error "Oops!! No matching projects found for this web-hook"
  end
end

def launch_hook
  $scheduler = Rufus::Scheduler.new if $scheduler.nil?
  # No need to initiate new scheduler job if previous one is already running. 
  # The running job will pick from the bucket
  # return false if !$job.nil? && $job.running?
  # Changed 'in' to 'every'....unschedules once all buckets are deployed
  $job = $scheduler.every '30s', :job=>true do |job|
    if !$active_deploy && !$deploy_bucket.empty?
      deploy
    # elsif $deploy_bucket.empty?
    #   job.unschedule
    end
  end
end

# put in the logic to wait for few seconds & then run
def deploy

  $active_deploy = true
  bucket = JSON.parse($deploy_bucket.last.to_json)
  unless bucket.nil?
    puts "Deploying code for: #{bucket.inspect}"
    system("./deploy.sh #{bucket['git_account']} #{bucket['launch_branch_name']} #{bucket['git_appname']} #{bucket['heroku_appname']} #{bucket['folder_name']}")
  end
  $deploy_bucket.pop
  puts "Now making active_deploy as false"
  $active_deploy = false
  check_build bucket
end

def check_build(build)

  return false if(build["report_to"].nil? || build["report_to"].empty?)
  
  build = JSON.parse(build.to_json)

  message = nil

  puts "Sending email reports to #{build['report_to']}"
  email_arr = []
  build["report_to"].each { |email|  
    email_arr.push({"email"=>email})
  }

  begin
    releases = $heroku.get_releases(build['heroku_appname'])
    last_rel = releases.body.last
    release_time = Time.parse(last_rel["created_at"]).to_i
    update_time = build["last_build"]/1000
    puts "Update Time: #{update_time}"
    puts "Release Time: #{release_time}"
  rescue Exception => e
    message = message = {"html"=>"<p>Build Status: Was unable to obtain build status</p><p>App Name: #{build['heroku_appname']}</p><p> Attempted Commit: <a href='https://github.com/#{build['git_account']}/#{build['git_appname']}/commit/#{build['sha']}'>#{build['last_commit']}</a></p><p>Last Deployed At: #{last_rel['created_at']}</p>", "subject"=>"Deploy Undeterminate", "from_email"=>"gheroku@liftoffllc.com", "to"=>email_arr}
  end
    
  # url = "https://api.heroku.com/apps/#{build['heroku_appname']}/builds"
  # response = JSON.parse(RestClient.get url, "Accept"=>"application/vnd.heroku+json;version=3").last
  # time_now = Time.now().to_i
  # created_at = Time.parse(response['created_at']).to_i
  if(message.nil?)
    if release_time > update_time
      message = {"html"=>"<p>Build Status: Successfull</p><p>App Name: #{build['heroku_appname']}</p><p> Commit: <a href='https://github.com/#{build['git_account']}/#{build['git_appname']}/commit/#{build['sha']}'>#{build['last_commit']}</a></p><p>Deployed At: #{last_rel['created_at']}</p>", "subject"=>"Deploy Successfull", "from_email"=>"gheroku@liftoffllc.com", "to"=>email_arr}
    else
      message = {"html"=>"<p>Build Status: Failed</p><p>App Name: #{build['heroku_appname']}</p><p> Attempted Commit: <a href='https://github.com/#{build['git_account']}/#{build['git_appname']}/commit/#{build['sha']}'>#{build['last_commit']}</a></p><p>Last Deployed At: #{last_rel['created_at']}</p>", "subject"=>"Deploy Failed", "from_email"=>"gheroku@liftoffllc.com", "to"=>email_arr}
    end
  end
  result = $mandrill.messages.send message
end
launch_hook