/*
 *  Scene.mm
 *  WhirlyGlobeLib
 *
 *  Created by Steve Gifford on 1/3/11.
 *  Copyright 2011-2012 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "Scene.h"
#import "GlobeView.h"
#import "GlobeMath.h"
#import "TextureAtlas.h"
#import "ScreenSpaceGenerator.h"
#import "ViewPlacementGenerator.h"

namespace WhirlyKit
{
    
Scene::Scene(WhirlyKit::CoordSystem *coordSystem,Mbr localMbr,unsigned int depth)
    : coordSystem(coordSystem)
{
    cullTree = new CullTree(coordSystem,localMbr,depth);

    // Also toss in a screen space generator to share amongst the layers
    ssGen = new ScreenSpaceGenerator(kScreenSpaceGeneratorShared,Point2f(0.1,0.1));
    screenSpaceGeneratorID = ssGen->getId();
    generators.insert(ssGen);
    // And put in a UIView placement generator for use in the main thread
    vpGen = new ViewPlacementGenerator(kViewPlacementGeneratorShared);
    generators.insert(vpGen);
    
    activeModels = [NSMutableArray array];
    
    pthread_mutex_init(&changeRequestLock,NULL);
}

Scene::~Scene()
{
    delete cullTree;
    for (TextureSet::iterator it = textures.begin(); it != textures.end(); ++it)
        delete *it;
    for (GeneratorSet::iterator it = generators.begin(); it != generators.end(); ++it)
        delete *it;
    
    pthread_mutex_destroy(&changeRequestLock);
    
    for (unsigned int ii=0;ii<changeRequests.size();ii++)
        delete changeRequests[ii];
    changeRequests.clear();
    
    activeModels = nil;
    
    subTextureMap.clear();
}
    
SimpleIdentity Scene::getGeneratorIDByName(const std::string &name)
{
    for (GeneratorSet::iterator it = generators.begin();
         it != generators.end(); ++it)
    {
        Generator *gen = *it;
        if (!name.compare(gen->name))
            return gen->getId();
    }
    
    return EmptyIdentity;
}

// Add change requests to our list
void Scene::addChangeRequests(const std::vector<ChangeRequest *> &newChanges)
{
    pthread_mutex_lock(&changeRequestLock);
    
    changeRequests.insert(changeRequests.end(),newChanges.begin(),newChanges.end());
    
    pthread_mutex_unlock(&changeRequestLock);
}

// Add a single change request
void Scene::addChangeRequest(ChangeRequest *newChange)
{
    pthread_mutex_lock(&changeRequestLock);
    
    changeRequests.push_back(newChange);
    
    pthread_mutex_unlock(&changeRequestLock);
}

GLuint Scene::getGLTexture(SimpleIdentity texIdent)
{
    if (texIdent == EmptyIdentity)
        return 0;
    
    Texture dumbTex;
    dumbTex.setId(texIdent);
    TextureSet::iterator it = textures.find(&dumbTex);
    if (it != textures.end())
        return (*it)->getGLId();
    
    return 0;
}

DrawableRef Scene::getDrawable(SimpleIdentity drawId)
{
    BasicDrawable *dumbDraw = new BasicDrawable();
    dumbDraw->setId(drawId);
    Scene::DrawableRefSet::iterator it = drawables.find(DrawableRef(dumbDraw));
    if (it != drawables.end())
        return *it;
    
    return DrawableRef();
}

Generator *Scene::getGenerator(SimpleIdentity genId)
{
    Generator dumbGen;
    dumbGen.setId(genId);
    GeneratorSet::iterator it = generators.find(&dumbGen);
    if (it != generators.end())
        return *it;
    
    return NULL;
}
    
void Scene::addActiveModel(NSObject<WhirlyKitActiveModel> *activeModel)
{
    [activeModels addObject:activeModel];
    [activeModel startWithScene:this];
}
    
void Scene::removeActiveModel(NSObject<WhirlyKitActiveModel> *activeModel)
{
    if ([activeModels containsObject:activeModel])
    {
        [activeModels removeObject:activeModel];
        [activeModel shutdown];
    }
}

Texture *Scene::getTexture(SimpleIdentity texId)
{
    Texture dumbTex;
    dumbTex.setId(texId);
    Scene::TextureSet::iterator it = textures.find(&dumbTex);
    if (it != textures.end())
        return *it;
    
    return NULL;
}

// Process outstanding changes.
// We'll grab the lock and we're only expecting to be called in the rendering thread
void Scene::processChanges(WhirlyKitView *view,NSObject<WhirlyKitESRenderer> *renderer)
{
    // We're not willing to wait in the rendering thread
    if (!pthread_mutex_trylock(&changeRequestLock))
    {
        for (unsigned int ii=0;ii<changeRequests.size();ii++)
        {
            ChangeRequest *req = changeRequests[ii];
            req->execute(this,renderer,view);
            delete req;
        }
        changeRequests.clear();
        
        pthread_mutex_unlock(&changeRequestLock);
    }
}
    
bool Scene::hasChanges()
{
    bool changes = false;
    if (!pthread_mutex_trylock(&changeRequestLock))
    {
        changes = !changeRequests.empty();
        
        pthread_mutex_unlock(&changeRequestLock);            
    }        
    
    return changes;
}

// Add a single sub texture map
void Scene::addSubTexture(const SubTexture &subTex)
{
    subTextureMap.insert(subTex);
}

// Add a whole group of sub textures maps
void Scene::addSubTextures(const std::vector<SubTexture> &subTexes)
{
    subTextureMap.insert(subTexes.begin(),subTexes.end());
}

// Look for a sub texture by ID
SubTexture Scene::getSubTexture(SimpleIdentity subTexId)
{
    SubTexture dumbTex;
    dumbTex.setId(subTexId);
    SubTextureSet::iterator it = subTextureMap.find(dumbTex);
    if (it == subTextureMap.end())
    {
        SubTexture passTex;
        passTex.trans = passTex.trans.Identity();
        passTex.texId = subTexId;
        return passTex;
    }
    
    return *it;
}
        
SimpleIdentity Scene::getScreenSpaceGeneratorID()
{
    return screenSpaceGeneratorID;
}

void Scene::dumpStats()
{
    NSLog(@"Scene: %ld drawables",drawables.size());
    NSLog(@"Scene: %d active models",[activeModels count]);
    NSLog(@"Scene: %ld generators",generators.size());
    NSLog(@"Scene: %ld textures",textures.size());
    NSLog(@"Scene: %ld sub textures",subTextureMap.size());
    cullTree->dumpStats();
    memManager.dumpStats();
    for (GeneratorSet::iterator it = generators.begin();
         it != generators.end(); ++it)
        (*it)->dumpStats();
}


void AddTextureReq::execute(Scene *scene,NSObject<WhirlyKitESRenderer> *renderer,WhirlyKitView *view)
{
    if (!tex->getGLId())
        tex->createInGL(true,scene->getMemManager());
    scene->textures.insert(tex);
    tex = NULL;
}

void RemTextureReq::execute(Scene *scene,NSObject<WhirlyKitESRenderer> *renderer,WhirlyKitView *view)
{
    Texture dumbTex;
    dumbTex.setId(texture);
    Scene::TextureSet::iterator it = scene->textures.find(&dumbTex);
    if (it != scene->textures.end())
    {
        Texture *tex = *it;
        tex->destroyInGL(scene->getMemManager());
        scene->textures.erase(it);
        delete tex;
    }
}

void AddDrawableReq::execute(Scene *scene,NSObject<WhirlyKitESRenderer> *renderer,WhirlyKitView *view)
{
    DrawableRef drawRef(drawable);
    scene->addDrawable(drawRef);
        
    // Initialize any OpenGL foo
    // Note: Make the Z offset a parameter
    drawable->setupGL([view calcZbufferRes],scene->getMemManager());
    
    drawable->updateRenderer(renderer);
        
    drawable = NULL;
}

void RemDrawableReq::execute(Scene *scene,NSObject<WhirlyKitESRenderer> *renderer,WhirlyKitView *view)
{
    BasicDrawable *dumbDraw = new BasicDrawable();
    dumbDraw->setId(drawable);
    Scene::DrawableRefSet::iterator it = scene->drawables.find(DrawableRef(dumbDraw));
    if (it != scene->drawables.end())
    {
        // Teardown OpenGL foo
        (*it)->teardownGL(scene->getMemManager());

        scene->remDrawable(*it);        
    }
}

void AddGeneratorReq::execute(Scene *scene,NSObject<WhirlyKitESRenderer> *renderer,WhirlyKitView *view)
{
    // Add the generator
    scene->generators.insert(generator);
    
    generator = NULL;
}

void RemGeneratorReq::execute(Scene *scene,NSObject<WhirlyKitESRenderer> *renderer,WhirlyKitView *view)
{
    Generator dumbGen;
    dumbGen.setId(genId);
    GeneratorSet::iterator it = scene->generators.find(&dumbGen);
    if (it != scene->generators.end())
    {
        Generator *theGenerator = *it;
        scene->generators.erase(it);
        
        delete theGenerator;
    }
}
    
NotificationReq::NotificationReq(NSString *inNoteName,NSObject *inNoteObj)
{
    noteName = inNoteName;
    noteObj = inNoteObj;
}

NotificationReq::~NotificationReq()
{
    noteName = nil;
    noteObj = nil;
}

void NotificationReq::execute(Scene *scene,NSObject<WhirlyKitESRenderer> *renderer,WhirlyKitView *view)
{
    NSString *theNoteName = noteName;
    NSObject *theNoteObj = noteObj;
    
    // Send out the notification on the main thread
    dispatch_async(dispatch_get_main_queue(),
                   ^{
                       [[NSNotificationCenter defaultCenter] postNotificationName:theNoteName object:theNoteObj];
                   });
}
    
}
