Db = require 'db'
Time = require 'time'
Form = require 'form'
Dom = require 'dom'
Modal = require 'modal'
Obs = require 'obs'
Plugin = require 'plugin'
Server = require 'server'
Ui = require 'ui'
Num = require 'num'
{tr} = require 'i18n'

inPoly = (point, poly) ->
	isOdd = false
	i2 = poly.length-1
	for corner1,i1 in poly
		corner2 = poly[i2]
		if (corner1.y<point.y && corner2.y>=point.y) || (corner2.y<point.y && corner1.y>=point.y)
			if (corner1.x+(point.y-corner1.y)/(corner2.y-corner1.y)*(corner2.x-corner1.x)<point.x)
				isOdd = !isOdd
		i2 = i1
	isOdd

interpolate = (p1,p2,p2weight=0.5) ->
	x: p1.x + (p2.x - p1.x)*p2weight
	y: p1.y + (p2.y - p1.y)*p2weight

blend = (p, c0, c1='#ffffff') ->
	f = parseInt(c0.slice(1),16)
	t = parseInt(c1.slice(1),16)
	r1=f>>16
	g1=f>>8&255
	b1=f&255
	r2=t>>16
	g2=t>>8&255
	b2=t&255
	"#"+(0x1000000+(Math.round((r2-r1)*p)+r1)*0x10000+(Math.round((g2-g1)*p)+g1)*0x100+(Math.round((b2-b1)*p)+b1)).toString(16).slice(1)

exports.render = !->
	userId = Plugin.userId()
	countries = Db.shared.get('countries')
	players = Db.shared.peek('players')
	userIds = []
	userNames = {}
	for player,x of players
		userIds.push 0|player
		userNames[player] = Plugin.userName(player)
	userIds.sort (a,b) ->
		a = userNames[a]
		b = userNames[b]
		if a<b then -1 else if a>b then 1 else 0

	Dom.style padding: 0
	
	showRound = Obs.create Db.shared.peek('round')
	Obs.observe !->
		showRound.set Db.shared.get('round')

	roundArrow = (dir,enable) !->
		Dom.div !->
			c = if enable then Plugin.colors().highlight else "#666"
			t = "transparent"
			Dom.style
				width: 0
				height: 0
				margin: "-4px 0"
				display: "inline-block"
				verticalAlign: "middle"
				borderStyle: "solid"
				borderWidth: "12px #{if dir>0 then 0 else 24}px 12px #{if dir>0 then 24 else 0}px"
				borderColor: t+" "+(if dir>0 then t else c)+" "+t+" "+(if dir>0 then c else t)
			if enable
				Dom.onTap !->
					showRound.set Math.min(Math.max(0,showRound.peek()+dir), Db.shared.peek('round'))
		
					
	infoItem = (title,content) !->
		Dom.div !->
			Dom.style textAlign: "center", Flex: true
			Dom.div !->
				Dom.text title
				Dom.style fontWeight: "bold"
			content()


	canvasHeight = Dom.viewport.get('height')
	Dom.div !->
		Dom.style
			padding: '6px'
			Box: "top"
		
		Obs.observe !->
			if winner = Db.shared.get('winner')
				infoItem tr("winner"), !->
					Dom.text userNames[winner]+'!'
			else
				infoItem tr("time"), !->
					Time.deltaText Db.shared.get('next'), [60,60,"%1m", 1,1,"%1s", 0,1,"1s"]
					Dom.onTap !->
						Modal.show tr "Time until the end of this round. Make sure you give your orders before then. Only at the end of the round will you see orders given by other players, and will all orders be executed, all at once."
	
		infoItem tr("goal ⚑"), !->
			goal = Db.shared.get 'goal'
			Dom.text tr "%1/%2", goal[0], goal[1]
			Dom.onTap !->
				Modal.show tr("Goal"), !->
					goal = Db.shared.get 'goal'
					Dom.userText tr "Of the %1 regions, %2 contain a flag. You can only see a flag once you have occupied its region. In order to win, you need to occupy the regions for any %3 flags at the same time.", countries.length, goal[1], goal[0]

		infoItem tr("players"), !->
			Dom.text userIds.length
			Dom.onTap !->
				renderPlayerColor = (player) !->
					Dom.div !->
						Dom.style
							backgroundColor: players[player].color
							display: 'inline-block'
							color: 'white'
							padding: '1px 4px'
							margin: '1px 2px'
							borderRadius: '2px'
						Dom.text userNames[player]
					Dom.text " "
				Modal.show !->
					renderPlayerColor userId
					for u in userIds when u!=userId
						renderPlayerColor u

		
		infoItem tr("round"), !->
			round = Db.shared.get('round')
			sr = showRound.get()
			roundArrow -1,sr>0
			Dom.text " "+sr+" "
			roundArrow 1,sr<round
		canvasHeight -= Dom.height()
	
	Agent = Plugin.agent()
	canvasMultiplier = Agent.canvasMultiplier()
	if Agent.samsung and Agent.android<4.4 and Agent.android>=4
		# samsung draws over random pixels when the viewport is not scrollable :S
		canvasHeight++

	width = Dom.viewport.get('width')
	ratio = Db.shared.get('ratio') || 1.35
	canvasHeight = width*ratio if Math.abs(ratio-canvasHeight/width)>0.25 # aspect ratios too different

	Dom.canvas !->
		Dom.style
			width: width+'px'
			height: canvasHeight+'px'
		Dom.prop
			width: width*canvasMultiplier
			height: canvasHeight*canvasMultiplier
		scaleX = width/1000
		scaleY = canvasHeight/(1000*ratio)
		ctx = Dom.getContext '2d'
		ctx.scale canvasMultiplier,canvasMultiplier
		ctx.lineWidth = 1
		ctx.textAlign = 'center'

		override = Obs.create {}
		Obs.observe !->
			log JSON.stringify override.get()
		selected = null

		round = showRound.get()
		owners = Db.shared.get(round,'owners')
		endFlags = Db.shared.get('flags') # only set once the game has ended
		readyOrders = Db.shared.get(round,'orders')
		newOrders = if readyOrders then null else Db.personal.ref('orders')

		reverseOrders = Obs.create {}
		if readyOrders
			for from,[target,forPlayer] of readyOrders
				reverseOrders.set target, from, forPlayer
		else
			newOrders.observeEach (order) !->
				return unless xget = order.get() # this shouldn't happen, but sometimes does :(
				xsrc = order.key()
				[xtarget,xforPlayer] = xget
				reverseOrders.set xtarget, xsrc, xforPlayer
				Obs.onClean !->
					reverseOrders.set xtarget, xsrc, null

		# Modals become invalid when new round data comes in
		Modal.remove()

		drawCountry = (country, cn) !->
			Obs.observe !->
				ctx.beginPath()
				for corner,i in country.corners
					ctx[if i then 'lineTo' else 'moveTo'] scaleX*corner.x, scaleY*corner.y
				ctx.closePath()

				v = override.get(cn) || override.get('all')
				colorFunc = null
				if typeof v == 'string'
					color = v
				else
					color = players[owners[cn]].color
					if typeof v == 'function'
						colorFunc = v
						color = v color

				ctx.fillStyle = color
				ctx.fill()
				ctx.strokeStyle = "#fff"
				ctx.stroke()
				
				center = country.center

				reverseOrders.forEach cn, (order) !->
					source = countries[0|order.key()]
					forPlayer = order.get()

					corners = []
					for corner1 in country.corners
						for corner2 in source.corners
							if corner1.x==corner2.x and corner1.y==corner2.y
								corners.push corner1
					return if corners.length!=2 # invalid order, no neighbours
					
					# assert: target in country.neighbours
					ctx.beginPath()
					ncenter = interpolate(center, interpolate(corners[0], corners[1]), 0.5)
					ctx.moveTo scaleX*ncenter.x, scaleY*ncenter.y
					for i in [0...2]
						ctx.lineTo scaleX*corners[i].x, scaleY*corners[i].y,
					ctx.closePath()
					forColor = players[forPlayer].color
					forColor = blend(0.2, forColor, '#000000')if forPlayer==owners[cn]
					forColor = colorFunc forColor if colorFunc
					ctx.fillStyle = forColor
					ctx.fill()

				hasFlag = if endFlags then endFlags[cn] else Db.personal.get("flags",cn)
				ctx.font = (if hasFlag then 'bold ' else '')+'13px sans-serif'
				ctx.fillStyle = '#fff'
				#.substr(0,2)
				ctx.fillText country.name, scaleX*center.x, scaleY*center.y+(if hasFlag then 0 else 6)
				if hasFlag
					#ctx.fillText "⚑", scale*center.x, scale*center.y+17
					ctx.save()
					ctx.translate(scaleX*center.x-12, scaleY*center.y-3)
					ctx.scale(0.3,0.3)
					ctx.beginPath()
					ctx.moveTo(49.1,29.2)
					ctx.bezierCurveTo(38.7,24,30.4,24.7,30.4,24.7)
					ctx.lineTo(30.4,71.3)
					ctx.bezierCurveTo(30.4,71.3,34.3,72,34.3,69.6)
					ctx.bezierCurveTo(34.3,67.2,34.3,49.7,34.3,49.7)
					ctx.bezierCurveTo(36.5,49,40.4,48.3,49.1,54)
					ctx.bezierCurveTo(60.3,60.6,65.5,52,65.5,52)
					ctx.lineTo(65.5,27.2)
					ctx.bezierCurveTo(65.5,27.2,59.6,34.1,49.1,29.2)
					ctx.closePath()
					ctx.fill()
					ctx.stroke()
					ctx.restore()
		
		for country,cn in countries
			drawCountry country,cn

		canvas = Dom.get()

		Dom.onTap (event) !->
			pos = event.getTouchXY canvas
			pos.x /= scaleX
			pos.y /= scaleY
			for country,cn in countries
				if !inPoly(pos,country.corners)
					continue
				owner = owners[cn]
				if newOrders
					if selected?
						setOrder = (order) !->
							if order!=false
								Server.sync 'order', selected, order, !->
									newOrders.set selected, order
							override.set {}
							selected = null
						if selected not in country.neighbours
							setOrder null
							return
						if owner==userId
							setOrder [cn,owner,owners[cn]]
							return
						renderPlayerOption = (u,txt) !->
							Ui.item !->
								Dom.style
									Box: "middle"
									color: 'white'
									fontWeight: 'bold'
									backgroundColor: players[u].color
								Ui.avatar Plugin.userAvatar u
								Dom.div !->
									Dom.style marginLeft: '8px'
									Dom.text userNames[u]
									if txt
										Dom.div !->
											Dom.style fontStyle: 'italic', fontSize: '85%', fontWeight: 'normal'
											Dom.text txt
								Dom.onTap !->
									setOrder [cn,u,owners[cn]]
									Modal.remove()
						Modal.show
							title: countries[selected].name,
							content: !->
								Dom.div !->
									Dom.style
										maxHeight: '45%'
										overflow: 'auto'
									Dom.div !->
										Dom.text tr("Let's fight in %1-occupied %2! Whose side are we on?",userNames[owner],country.name)
										Dom.style marginBottom: '8px'
									renderPlayerOption userId, tr('attack')
									renderPlayerOption owner, tr('assist defence')
									for u in userIds when u not in [userId,owner]
										renderPlayerOption u, tr('assist attack')
							cb: setOrder
							buttons: [false,tr('Never mind')]
						return

					if owner == userId
						o = {all: bindArgs(blend,0.5)}
						pos = 0
						o[cn] = (c) ->
							pos += 0.25
							opacity = 0.2 - 0.2*Math.cos(pos)
							Obs.delay 1000/30
							blend(opacity,c)
						for neighbour in country.neighbours
							o[neighbour] = true
						override.set o
						selected = cn
						return
				Modal.show country.name, !->
					Ui.avatar Plugin.userAvatar(owner), !->
						Dom.style
							position: 'absolute'
							right: '-10px'
							top: '-10px'
					, 50, (!-> Plugin.userInfo(owner))
					Dom.text tr "Occupied by %1.",userNames[owner]
					return unless readyOrders
					forces = {}
					forces[owner] = {defence:10}
					forces[owner][country.name] = 10 if !readyOrders[cn]
					for src, forPlayer of reverseOrders.peek(cn)
						(forces[forPlayer] ||= [])[countries[src].name] = (if forPlayer==owners[src] then 10 else 11)
					Dom.br()
					awinner = abest = false
					Dom.table !->
						Dom.prop cellSpacing: "10px"
						for u,force of forces
							Dom.tr !->
								Dom.style padding: '2px 4px'
								Dom.td userNames[u]
								score = 0
								text = []
								for k,v of force
									text.push k+': '+v
									score += v
								Dom.td score
								Dom.userText text.join("\n")
								if abest==false or score>=abest
									if score==abest
										awinner = false
									else
										awinner = 0|u
									abest = score
					if awinner==false
						Dom.text tr "Standoff! %1 gets to keep the region.", userNames[owner]
					else if awinner==owner
						Dom.text tr "%1 gets to keep the region.", userNames[owner]
					else
						Dom.text tr "%1 conquers the region!", userNames[awinner]
				return

			#	Ui.bigButton 'new game', !->
			#		Server.call 'new'


exports.renderSettings = !->
	Dom.div !->
		Dom.style Box: "middle", padding: '12px 40px 12px 8px'
		Dom.div !->
			Dom.style Flex: true
			Dom.text tr "Round time in minutes"
		Num.render
			name: 'time'
			value: (if Db.shared then Db.shared.peek('interval') else 0)||360
	if Db.shared
		Form.check
			name: 'restart'
			text: tr 'Restart'
			sub: tr 'Check this to destroy the current game and start a new one.'

