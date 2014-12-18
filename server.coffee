Db = require 'db'
Plugin = require 'plugin'
Timer = require 'timer'
Event = require 'event'
{Voronoi} = require 'voronoi'
{tr} = require 'i18n'

allNames = "Aldam Arua Axil Ayela Azua Beso Casal Ceio Cocez Dequa Dodor Ecrus Egen Esua Feji Foburg Furl Goji Hajan Henus Idraz Ison Jedan Kostein Kule Lasa Lezon Mador Modan Netho Ogon Ofrar Oispa Osta Pecor Qador Rona Santon Selor Tasil Teria Upar Uwait Uxel Vocia Vucor Warii Wulor Xoji Zuze".split " "

rndf = (min,max) -> Math.random()*(max-min)+min
rndi = (min,maxExcl) -> 0|Math.random()*(maxExcl-min)+min
getXY = (org) -> {x:Math.round(org.x), y:Math.round(org.y)}

polyArea = (poly) ->
	area = 0
	i2 = poly.length-1
	for corner1,i1 in poly
		corner2 = poly[i2]
		area += (corner2.x+corner1.x) * (corner2.y-corner1.y)
		i2 = i1
	area/2

hueToRgb = (p, q, t) ->
	t+=1 if t < 0
	t-=1 if t > 1
	if t < 1/6
		p + (q - p) * 6 * t
	else if t < 1/2
		q
	else if t < 2/3
		p + (q - p) * (2/3 - t) * 6
	else
		p

hslToRgb = (h, s, l) ->
	if !s
		rgb = [l,l,l] # achromatic
	else
		q = if l < 0.5 then l * (1 + s) else l + s - l * s
		p = 2 * l - q
		rgb = [
			hueToRgb p, q, h + 1/3
			hueToRgb p, q, h
			hueToRgb p, q, h - 1/3
		]
	'#' + (("0"+Math.round(c*255).toString(16)).substr(-2) for c in rgb).join ''

makeMap = ->
	userIds = Plugin.userIds()

	count = Math.min(10 + userIds.length * 4, 45)
	count = (0|(count/userIds.length)) * userIds.length
	count = Math.max(count, userIds.length*2)

	sites = ({x: rndf(25,1000-25), y: rndf(25,1250-25)} for i in [0...count])
	box = {xl:0, xr:1000, yt:0,yb:1250}
	voronoi = new Voronoi()
	
	# regularize the random points a bit using 3 passes of Lloyd Relaxation
	# http://www-cs-students.stanford.edu/~amitp/game-programming/polygon-map-generation/demo.html
	for i in [0...3]
		diagram = voronoi.compute(sites, box)
		for cell in diagram.cells
			x = y = 0
			for halfEdge in cell.halfedges
				corner = halfEdge.getStartpoint()
				x += corner.x
				y += corner.y
			cell.site.x = x/cell.halfedges.length
			cell.site.y = y/cell.halfedges.length

	countries = []
	diagram = voronoi.compute(sites, box)

	for cell in diagram.cells
		country =
			corners: []
			neighbours: []
			center: getXY(cell.site)

		cell.site.country = country
		countries.push country
	
	# Sort countries top-downish to assign names
	countries.sort (a,b) -> a.center.y+a.center.x/10 - b.center.y-b.center.x/10
	
	names = allNames.slice 0
	while names.length > countries.length
		names.splice rndi(0,names.length), 1

	for country,num in countries
		country.name = if countries.length <= names.length then names[num] else '#'+(1+num)
		country.num = num

	for cell in diagram.cells
		country = cell.site.country
		for halfEdge in cell.halfedges
			country.corners.push getXY(halfEdge.getStartpoint())
			edge = halfEdge.edge
			neighbour = if edge.lSite==cell.site then edge.rSite else edge.lSite
			if neighbour and neighbour.country
				country.neighbours.push neighbour.country.num
				neighbour.country.neighbours.push country.num

	owners = []
	flags = {}
	flagCount = 0
	personal = {}
	userHasFlag = {}
	for userId in userIds
		personal[userId] = {flags: {}}
	for country,num in countries
		owners[num] = userId = userIds[num % userIds.length]
		if !userHasFlag[userId]
			chancesLeft = 0 | ((countries.length-num-1)/userIds.length)
			if !rndi(0,1+chancesLeft)
				flags[num] = true
				flagCount++
				userHasFlag[userId] = true
		personal[userId].flags[num] = !!flags[num]
		delete country.num

	goal = [(if flagCount<4 then flagCount else (flagCount>>1)+1), flagCount]
	
	players = {}
	runs = if userIds.length<=6 then 1 else if userIds.length<=12 then 2 else 4
	run = 0
	hue = 0
	hueSteps = Math.ceil(userIds.length/runs)
	for userId,n in userIds
		players[userId] = {
			color: hslToRgb(
				hue/hueSteps
				(if runs<4 then 0.8 else if run<2 then 1 else 0.3)
				(if runs<2 then 0.35 else if run&1 then 0.15 else 0.4)
			)
		}
		if ++hue>=hueSteps
			hue = 0
			run++

	Db.shared.set
		countries: countries
		players: players
		goal: goal
		ratio: 1.25
		interval: Db.shared.get('interval')
		0:
			owners: owners
		round: 0
	Db.admin.set
		flags: flags
	
	savePersonal players, personal
	setTimer()
	
	Event.create
		unit: 'game'
		text: tr "A new game has started!"


setTimer = !->
	seconds = (Db.shared.get('interval')||120)*60
	Db.shared.set 'next', 0|Plugin.time()+seconds
	Timer.cancel 'go'
	Timer.set seconds*1000, 'go'

objEmpty = (obj) ->
	return false for x of obj
	true

arrDel = (arr,item) !->
	for value,i in arr
		if value==item
			arr.splice i,1
			break
		
		
removeInvalidOrders = (orders, owners, forUserId, countries) !->
	for cn,[target,forPlayer,targetOwner] of orders
		if owners[cn]!=forUserId or owners[target]!=targetOwner or (countries and target not in countries[cn].neighbours)
			delete orders[cn]

exports.go = !->
	log 'go!'
	if Db.shared.get('winner')
		log 'winner'
		return
	setTimer()
	if Db.shared.incr('idle')>2
		log 'idle'
		return

	players = Db.shared.get 'players'
	round = Db.shared.get('round')
	owners = Db.shared.get round, 'owners'
	countries = Db.shared.get 'countries'
	goal = Db.shared.get 'goal'
	flags = Db.admin.get 'flags'
	newOwners = owners.slice 0

	armies = {} # per target country per player
	orders = {}

	incrArmy = (target,forPlayer,delta) !->
		ca = (armies[target] ||= {})
		ca[forPlayer] = (ca[forPlayer]||0) + delta

	personal = {}

	for player,x of players
		player |= 0
		personal[player] = Db.personal(player).get()
		removeInvalidOrders personal[player].orders, owners, player, countries
		for cn,order of personal[player].orders
			orders[cn] = order
			incrArmy cn, player, -10
			incrArmy order[0], order[1], (if player==order[1] then 10 else 11)

	for target,sizes of armies
		# each country starts with 2 armies
		incrArmy target, owners[target], 20
		wsize = wplayer = 0
		for player,size of sizes
			if size>wsize
				wplayer = 0|player
				wsize = size
			else if size==wsize
				wplayer = 0 # equal forces? stand off!
		if wplayer
			newOwners[target] = wplayer # can be the old owner
			(personal[wplayer].flags ||= {})[target] = !!flags[target]
	
	for player,data of personal when data.orders
		removeInvalidOrders data.orders, newOwners, 0|player

	Db.shared.set round, 'orders', orders
	savePersonal players, personal
	round++

	winCnt = {}
	for flag,x of flags
		userId = owners[flag]
		winCnt[userId] = (winCnt[userId]||0)+1
	winner = false
	for userId,cnt of winCnt
		winner = 0|userId if cnt>=goal[0] and (winner==false or cnt>winCnt[winner])
	if winner
		Db.shared.set 'winner', winner
		Db.shared.set 'flags', flags
		Event.create
			unit: 'game'
			text: tr "We have a winner!"
	else
		Db.shared.set round, 'owners', newOwners
		Db.shared.set 'round', round
		Event.create
			unit: 'game'
			text: tr "Next round!"
	log "done"

exports.onInstall = (cfg = {}) !->
	cfg.restart = true
	onConfig(cfg)

exports.onConfig = onConfig = (cfg) !->
	Db.shared.set 'interval', cfg.time if cfg.time
	makeMap() if cfg.restart

exports.client_order = (cn,order) !->
	Db.shared.set 'idle', 0
	Db.personal().set 'orders', cn, order

savePersonal = (players, personal) !->
	for player,x of players
		Db.personal(player).set personal[player] || {}

