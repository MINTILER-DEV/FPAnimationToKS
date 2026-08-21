--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AnimationToKeyframeSequence = {}

----------------------------------------------------------------
-- TYPES
----------------------------------------------------------------

export type Options = {
	FrameRate: number?,
	SequenceName: string?,
	ParentCloneTo: Instance?,
	ClonePosition: CFrame?,
	KeepClone: boolean?,
}

type SupportedJoint = Motor6D | AnimationConstraint

type JointInfo = {
	Joint: SupportedJoint,
	Part0: BasePart,
	Part1: BasePart,
}

type JointTree = {
	[BasePart]: {JointInfo}
}

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function isSupportedJoint(
	instance: Instance
): boolean
	return instance:IsA("Motor6D")
		or instance:IsA("AnimationConstraint")
end

local function getJointParts(
	joint: SupportedJoint
): (BasePart?, BasePart?)

	if joint:IsA("Motor6D") then
		return joint.Part0, joint.Part1
	end

	-- AnimationConstraint
	--
	-- Roblox exposes Part0 / Part1 as aliases, but using the
	-- attachments directly makes the relationship obvious.

	local attachment0 = joint.Attachment0
	local attachment1 = joint.Attachment1

	if not attachment0 or not attachment1 then
		return nil, nil
	end

	local parent0 = attachment0.Parent
	local parent1 = attachment1.Parent

	if
		parent0
		and parent0:IsA("BasePart")
		and parent1
		and parent1:IsA("BasePart")
	then
		return parent0, parent1
	end

	return nil, nil
end

local function getJointTransform(
	joint: SupportedJoint
): CFrame
	return joint.Transform
end

----------------------------------------------------------------
-- CLONING
----------------------------------------------------------------

local function cloneRig(
	character: Model,
	options: Options
): Model

	local oldArchivable = character.Archivable

	character.Archivable = true

	local clone = character:Clone()

	character.Archivable = oldArchivable

	clone.Name = character.Name .. "_AnimationRecorder"

	------------------------------------------------------------
	-- Remove anything capable of running.
	------------------------------------------------------------

	for _, object in clone:GetDescendants() do
		if
			object:IsA("Script")
			or object:IsA("LocalScript")
		then
			object:Destroy()
		end
	end

	------------------------------------------------------------
	-- Remove existing Animator.
	--
	-- We want absolutely nothing playing except the animation
	-- we're sampling.
	------------------------------------------------------------

	local humanoid =
		clone:FindFirstChildOfClass("Humanoid")

	assert(
		humanoid,
		"Cloned character has no Humanoid"
	)

	local oldAnimator =
		humanoid:FindFirstChildOfClass("Animator")

	if oldAnimator then
		oldAnimator:Destroy()
	end

	------------------------------------------------------------
	-- Hide the recorder rig.
	------------------------------------------------------------

	for _, object in clone:GetDescendants() do
		if object:IsA("BasePart") then
			object.Transparency = 1
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
			object.CastShadow = false
		end
	end

	------------------------------------------------------------
	-- Place it somewhere harmless.
	------------------------------------------------------------

	clone.Parent =
		options.ParentCloneTo
		or Workspace

	local targetCFrame =
		options.ClonePosition
		or CFrame.new(0, -10000, 0)

	clone:PivotTo(targetCFrame)

	------------------------------------------------------------
	-- Keep the root from falling into oblivion.
	------------------------------------------------------------

	local root =
		clone:FindFirstChild("HumanoidRootPart")

	if root and root:IsA("BasePart") then
		root.Anchored = true
	end

	return clone
end

----------------------------------------------------------------
-- JOINT DISCOVERY
----------------------------------------------------------------

local function getJoints(
	rig: Model
): {JointInfo}

	local joints: {JointInfo} = {}

	for _, object in rig:GetDescendants() do
		if not isSupportedJoint(object) then
			continue
		end

		local joint =
			object :: SupportedJoint

		local part0, part1 =
			getJointParts(joint)

		-- Ignore incomplete / broken joints.
		if not part0 or not part1 then
			continue
		end

		-- Make sure both sides actually belong to this rig.
		if
			not part0:IsDescendantOf(rig)
			or not part1:IsDescendantOf(rig)
		then
			continue
		end

		table.insert(joints, {
			Joint = joint,
			Part0 = part0,
			Part1 = part1,
		})
	end

	return joints
end

local function buildJointTree(
	joints: {JointInfo}
): JointTree

	local tree: JointTree = {}

	for _, info in joints do
		local children =
			tree[info.Part0]

		if not children then
			children = {}

			tree[info.Part0] =
				children
		end

		table.insert(
			children,
			info
		)
	end

	return tree
end

----------------------------------------------------------------
-- FIND ROOT
----------------------------------------------------------------

local function findRigRoot(
	rig: Model,
	joints: {JointInfo}
): BasePart?

	------------------------------------------------------------
	-- Roblox characters normally use HumanoidRootPart.
	------------------------------------------------------------

	local hrp =
		rig:FindFirstChild("HumanoidRootPart")

	if hrp and hrp:IsA("BasePart") then
		return hrp
	end

	------------------------------------------------------------
	-- Generic fallback.
	--
	-- Find a Part0 which is never the Part1 of another joint.
	------------------------------------------------------------

	local childParts: {
		[BasePart]: boolean
	} = {}

	for _, info in joints do
		childParts[info.Part1] = true
	end

	for _, info in joints do
		if not childParts[info.Part0] then
			return info.Part0
		end
	end

	return nil
end

----------------------------------------------------------------
-- CREATE POSE TREE
----------------------------------------------------------------

local function createPoseTree(
	part: BasePart,
	tree: JointTree,
	visited: {[BasePart]: boolean}
): Pose

	visited[part] = true

	local pose =
		Instance.new("Pose")

	pose.Name = part.Name
	pose.CFrame = CFrame.identity
	pose.Weight = 1

	local children =
		tree[part]

	if not children then
		return pose
	end

	for _, info in children do

		--------------------------------------------------------
		-- Protect against malformed joint loops.
		--------------------------------------------------------

		if visited[info.Part1] then
			continue
		end

		local childPose =
			createPoseTree(
				info.Part1,
				tree,
				visited
			)

		--------------------------------------------------------
		-- THE IMPORTANT BIT
		--
		-- Works for:
		--
		-- Motor6D.Transform
		-- AnimationConstraint.Transform
		--------------------------------------------------------

		childPose.CFrame =
			getJointTransform(
				info.Joint
			)

		childPose.Parent =
			pose
	end

	return pose
end

----------------------------------------------------------------
-- CAPTURE FRAME
----------------------------------------------------------------

local function captureFrame(
	sequence: KeyframeSequence,
	root: BasePart,
	tree: JointTree,
	frameIndex: number,
	timePosition: number
)

	local keyframe =
		Instance.new("Keyframe")

	keyframe.Name =
		string.format(
			"Frame_%05d",
			frameIndex
		)

	keyframe.Time =
		timePosition

	local rootPose =
		createPoseTree(
			root,
			tree,
			{}
		)

	rootPose.Parent =
		keyframe

	sequence:AddKeyframe(
		keyframe
	)
end

----------------------------------------------------------------
-- WAIT FOR ANIMATOR EVALUATION
----------------------------------------------------------------

local function evaluateAt(
	track: AnimationTrack,
	animator: Animator,
	timePosition: number
)

	------------------------------------------------------------
	-- TimePosition can be manually moved while the track is
	-- playing.
	------------------------------------------------------------

	track.TimePosition =
		timePosition

	------------------------------------------------------------
	-- Animator evaluates between PreAnimation and
	-- PreSimulation.
	--
	-- Waiting until the NEXT PreSimulation means we've crossed
	-- an animation evaluation pass after changing TimePosition.
	------------------------------------------------------------

	repeat
		RunService.PreSimulation:Wait()
	until not animator.EvaluationThrottled
end

----------------------------------------------------------------
-- RESET JOINTS
----------------------------------------------------------------

local function resetTransforms(
	joints: {JointInfo}
)
	for _, info in joints do
		info.Joint.Transform =
			CFrame.identity
	end
end

----------------------------------------------------------------
-- MAIN CONVERTER
----------------------------------------------------------------

function AnimationToKeyframeSequence.Convert(
	character: Model,
	animation: Animation,
	options: Options?
): KeyframeSequence

	options = options or {}

	local frameRate =
		options.FrameRate
		or 30

	assert(
		frameRate > 0,
		"FrameRate must be greater than zero"
	)

	assert(
		animation.AnimationId ~= "",
		"Animation has no AnimationId"
	)

	------------------------------------------------------------
	-- CLONE PLAYER RIG
	------------------------------------------------------------

	local rig =
		cloneRig(
			character,
			options
		)

	------------------------------------------------------------
	-- Everything from here onward should clean the clone if
	-- something errors.
	------------------------------------------------------------

	local success, result =
		pcall(function()

			----------------------------------------------------
			-- HUMANOID
			----------------------------------------------------

			local humanoid =
				rig:FindFirstChildOfClass(
					"Humanoid"
				)

			assert(
				humanoid,
				"Recorder rig has no Humanoid"
			)

			----------------------------------------------------
			-- FRESH ANIMATOR
			----------------------------------------------------

			local animator =
				Instance.new("Animator")

			animator.Name =
				"AnimationRecorderAnimator"

			animator.PreferLodEnabled =
				false

			animator.Parent =
				humanoid

			----------------------------------------------------
			-- JOINTS
			----------------------------------------------------

			local joints =
				getJoints(rig)

			assert(
				#joints > 0,
				"Rig contains no Motor6Ds or AnimationConstraints"
			)

			local tree =
				buildJointTree(joints)

			local root =
				findRigRoot(
					rig,
					joints
				)

			assert(
				root,
				"Unable to determine rig root"
			)

			----------------------------------------------------
			-- OUTPUT SEQUENCE
			----------------------------------------------------

			local sequence =
				Instance.new(
					"KeyframeSequence"
				)

			sequence.Name =
				options.SequenceName
				or (
					animation.Name
					.. "_Converted"
				)

			----------------------------------------------------
			-- LOAD ANIMATION
			----------------------------------------------------

			local track =
				animator:LoadAnimation(
					animation
				)

			----------------------------------------------------
			-- Play at speed 0.
			--
			-- It's technically active, but time won't advance.
			----------------------------------------------------

			track:Play(
				0,
				1,
				0
			)

			----------------------------------------------------
			-- Wait until animation data loads.
			----------------------------------------------------

			while track.Length <= 0 do
				RunService.Heartbeat:Wait()
			end

			local length =
				track.Length

			----------------------------------------------------
			-- Copy metadata Roblox gives us.
			----------------------------------------------------

			sequence.Loop =
				track.Looped

			sequence.Priority =
				track.Priority

			----------------------------------------------------
			-- Initial Animator pass.
			----------------------------------------------------

			RunService.PreSimulation:Wait()

			----------------------------------------------------
			-- EXACT SAMPLING
			----------------------------------------------------

			local frameDuration =
				1 / frameRate

			local fullFrameCount =
				math.floor(
					length
					* frameRate
				)

			for frameIndex = 0, fullFrameCount do

				local timePosition =
					frameIndex
					* frameDuration

				timePosition =
					math.min(
						timePosition,
						length
					)

				evaluateAt(
					track,
					animator,
					timePosition
				)

				captureFrame(
					sequence,
					root,
					tree,
					frameIndex,
					timePosition
				)
			end

			----------------------------------------------------
			-- EXACT FINAL FRAME
			--
			-- If animation length isn't exactly divisible by
			-- frameDuration, append the true ending.
			----------------------------------------------------

			local lastFrameTime =
				fullFrameCount
				* frameDuration

			if
				math.abs(
					length
					- lastFrameTime
				) > 0.000001
			then

				evaluateAt(
					track,
					animator,
					length
				)

				captureFrame(
					sequence,
					root,
					tree,
					fullFrameCount + 1,
					length
				)
			end

			----------------------------------------------------
			-- CLEAN TRACK
			----------------------------------------------------

			track:Stop(0)
			track:Destroy()

			resetTransforms(
				joints
			)

			return sequence
		end)

	------------------------------------------------------------
	-- DESTROY TEMP RIG
	------------------------------------------------------------

	if not options.KeepClone then
		rig:Destroy()
	end

	------------------------------------------------------------
	-- PROPAGATE ERRORS
	------------------------------------------------------------

	if not success then
		error(
			"Animation conversion failed: "
			.. tostring(result)
		)
	end

	return result :: KeyframeSequence
end

return AnimationToKeyframeSequence
